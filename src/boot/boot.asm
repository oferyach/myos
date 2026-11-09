; =============================================================================
; boot.asm — MyOS Bootloader + Disk Read → 32-bit Kernel
; =============================================================================
;
; Disk layout (floppy):
;   Sector 0  (0x000-0x1FF) → This boot sector, loaded by BIOS to 0x7C00
;   Sector 1  (0x200-0x3FF) → 32-bit kernel code (we read it into 0x7E00)
;
; What this does:
;   1. Init segments / stack (real mode)
;   2. Clear screen via BIOS
;   3. Read sector 1 from disk into memory at 0x7E00
;   4. Load GDT
;   5. Enable A20 line
;   6. Switch to 32-bit protected mode
;   7. Far jump to kernel at 0x7E00
; =============================================================================
ORG 0x7C00
[BITS 16]

; -----------------------------------------------------------------------------
; Entry point — BIOS loads us here
; -----------------------------------------------------------------------------
start16:
    cli                         ; Disable interrupts during setup
    xor     ax, ax
    mov     ss, ax
    mov     sp, 0x7C00          ; Stack below our code
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    sti

    mov     [boot_drv], dl      ; Save boot drive number (BIOS puts it in DL)

; -----------------------------------------------------------------------------
; Clear screen via BIOS video interrupt
; -----------------------------------------------------------------------------
    mov     ax, 0x0600          ; Scroll up (clear screen)
    mov     bx, 0x0700          ; Light grey on black
    mov     cx, 0               ; Top-left: row 0, col 0
    mov     dx, 0x184F          ; Bottom-right: row 24, col 79
    int     0x10

; -----------------------------------------------------------------------------
; Read kernel from disk into memory
;   Read 1 sector (sector 2, which is LBA 1) into ES:BX = 0700:0000 (0x07E00)
;   CHS: cylinder 0, head 0, sector 2
; -----------------------------------------------------------------------------
    mov     ax, 0
    mov     es, ax
    mov     bx, 0x7E00          ; Load kernel at physical address 0x07E00
    mov     dl, [boot_drv]      ; Our boot drive
    mov     ch, 0               ; Cylinder 0
    mov     dh, 0               ; Head 0
    mov     cl, 2               ; Sector 2 (first sector after boot sector)
    mov     ah, 0x02            ; BIOS: read disk sectors into ES:BX
    mov     al, 1               ; Read 1 sector
    int     0x13
    jc      .read_failed         ; If carry, disk read error
    cmp     al, 1               ; Did we read 1 sector?
    jne     .read_failed

; -----------------------------------------------------------------------------
; Load GDT
; -----------------------------------------------------------------------------
    lgdt    [gdt_desc]

; -----------------------------------------------------------------------------
; Enable A20 line (BIOS method: INT 15h, AX=2401h)
; -----------------------------------------------------------------------------
    mov     ax, 0x2401
    int     0x15

; -----------------------------------------------------------------------------
; Switch to Protected Mode
; -----------------------------------------------------------------------------
    cli                         ; No interrupts during the flip
    mov     eax, cr0
    or      eax, 1              ; Set PE (Protection Enable) bit
    mov     cr0, eax

; -----------------------------------------------------------------------------
; Far jump to 32-bit kernel at 0x0000:0x7E00
;   Selector 0x08 = our code segment (index 1 in GDT)
;   Offset 0x7E00 = where the kernel was loaded
; -----------------------------------------------------------------------------
    jmp     0x08:0x7E00

; -----------------------------------------------------------------------------
; Disk read error (shouldn't happen but let's be safe)
; -----------------------------------------------------------------------------
.read_failed:
    mov     si, err_msg
.print_err:
    lodsb
    or      al, al
    jz      hang
    mov     ah, 0x0E
    mov     bx, 0x0007
    int     0x10
    jmp     .print_err
hang:
    cli
    hlt
    jmp     hang

; -----------------------------------------------------------------------------
; GDT: [Null] [Code 32-bit] [Data]
; -----------------------------------------------------------------------------
gdt_start:
    dd 0, 0                         ; Null descriptor (required at index 0)
    dw  0xFFFF, 0x0000             ; Code: limit=4GB, base=0
    db  0x00, 0x9A, 0xCF, 0x00     ; Code, read-execute, present, 4K gran
    dw  0xFFFF, 0x0000             ; Data: limit=4GB, base=0
    db  0x00, 0x92, 0xCF, 0x00     ; Data, read-write, present, 4K gran
gdt_end:

gdt_desc:
    dw  gdt_end - gdt_start - 1    ; GDT limit (size - 1)
    dd  gdt_start                  ; GDT base address (physical)

; -----------------------------------------------------------------------------
; Variables
; -----------------------------------------------------------------------------
boot_drv:     db  0                ; BIOS boot drive number

; -----------------------------------------------------------------------------
; Error message
; -----------------------------------------------------------------------------
err_msg db "Disk read error!", 0

; -----------------------------------------------------------------------------
; Pad to 510 bytes, then boot signature at 510-511
; -----------------------------------------------------------------------------
times 510 - ($ - $$) db 0
dw  0xAA55

; -----------------------------------------------------------------------------
; NOTE: The 32-bit kernel code is at file offset 512+ (sector 1 on disk).
;       It's loaded into memory at 0x7E00 by the DISK READ above.
;       The 32-bit code follows below, assembled at ORG 0x7C00 + 512 = 0x7E00.
; -----------------------------------------------------------------------------

; =============================================================================
; Stage 2: 32-bit Protected Mode Kernel (loaded at 0x7E00)
; =============================================================================
[BITS 32]

VGA equ 0xB8000                   ; VGA text-mode memory-mapped buffer

kernel_start:
    ; Initialize all segment registers with data selector
    mov     ax, 0x10              ; Data segment = GDT index 2 = 0x10
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     fs, ax
    mov     gs, ax
    mov     esp, 0x90000          ; Stack at 6 MB

    ; === Clear the entire screen ===
    mov     di, 0                 ; Offset within VGA buffer
    mov     ecx, 80 * 25          ; 2000 cells
    xor     ax, ax
    rep     stosw
    xor     di, di

    ; === Print: Title "  MyOS  " ===
    ;   Row 0, col 32 → offset = (80*0+32)*2 = 0x0040
    mov     edi, VGA
    add     edi, 2*(80*0+32)
    mov     esi, str_title
    mov     ch, 0x1B              ; Cyan on blue
    call    vga_puts

    ; === Print: "Booting in 32-bit Protected Mode..." ===
    ;   Row 2, col 8
    mov     edi, VGA
    add     edi, 2*(80*2+8)
    mov     esi, str_mode
    mov     ch, 0x0F              ; White on black
    call    vga_puts

    ; === Print: "CPU: x86 Protected Mode" ===
    ;   Row 3, col 8
    mov     edi, VGA
    add     edi, 2*(80*3+8)
    mov     esi, str_cpu
    mov     ch, 0x0E              ; Yellow on black
    call    vga_puts

    ; === Print: "Memory: 1 MB (A20 enabled)" ===
    ;   Row 4, col 8
    mov     edi, VGA
    add     edi, 2*(80*4+8)
    mov     esi, str_mem
    mov     ch, 0x02              ; Green on black
    call    vga_puts

    ; === Separator line at row 6 ===
    mov     edi, VGA
    add     edi, 2*(80*6)
    mov     ecx, 80
    mov     ax, 0x027E            ; '~' in green
    rep     stosw

    ; === Print: "[OK] Protected Mode Active" ===
    ;   Row 7, col 8
    mov     edi, VGA
    add     edi, 2*(80*7+8)
    mov     esi, str_ok
    mov     ch, 0x22              ; Green on green
    call    vga_puts

    ; === Print: "Segmentation: flat, 0-4GB" ===
    ;   Row 9, col 8
    mov     edi, VGA
    add     edi, 2*(80*9+8)
    mov     esi, str_seg
    mov     ch, 0x03              ; Cyan on black
    call    vga_puts

    ; === Print: "Ready." ===
    ;   Row 11, col 8
    mov     edi, VGA
    add     edi, 2*(80*11+8)
    mov     esi, str_ready
    mov     ch, 0x2F              ; Light green on white
    call    vga_puts

; -----------------------------------------------------------------------------
; Halt forever
; -----------------------------------------------------------------------------
.k:
    hlt
    jmp     .k

; ============================================================
; Function: vga_puts
;   Prints a null-terminated string at VGA offset [EDI]
;   Attribute byte in CH
;   Preserves all registers
; ============================================================
vga_puts:
    pusha
.loop:
    mov     al, [esi]             ; Load character
    test    al, al                ; Null terminator?
    jz      .end
    inc     esi
    mov     ah, ch                ; Attribute in AH
    mov     [edi], ax             ; Write char + attr to VGA
    add     edi, 2                ; Next cell (2 bytes each)
    jmp     .loop
.end:
    popa
    ret

; ============================================================
; Strings — null-terminated
; ============================================================
str_title db '  MyOS  ', 0
str_mode  db 'Booting in 32-bit Protected Mode...    ', 0
str_cpu   db 'CPU: x86 Protected Mode', 0
str_mem   db 'Memory: 1 MB (A20 enabled)', 0
str_ok    db '[OK] Protected Mode Active', 0
str_seg   db 'Segmentation: flat, 0-4GB', 0
str_ready db 'Ready.', 0
