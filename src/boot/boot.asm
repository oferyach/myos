; =============================================================================
; boot.asm — Stage 1: the boot sector (exactly 512 bytes)
; -----------------------------------------------------------------------------
; Assembled with `nasm -f bin` → raw binary, no headers, no relocations.
; The BIOS reads sector 1 of the floppy, loads it at physical 0x7C00,
; and jumps to it. The last 2 bytes MUST be 0x55 0xAA (the boot signature)
; or the BIOS refuses to boot the image.
;
; What this stage does, in order:
;   1. Sets up segment registers + stack, saves the BIOS-provided drive
;      number (DL).
;   2. Clears the 80x25 text screen via INT 0x10.
;   3. Reads the kernel (8 sectors starting at floppy sector 2) into
;      memory at 0x7E00 via INT 0x13 (floppy has no partitions).
;   4. Loads a minimal 3-entry GDT, enables the A20 line, sets the PE bit
;      in CR0, and far-jumps into the 32-bit kernel at 0x7E00.
; =============================================================================

; Tell the assembler where this code will physically live when the BIOS
; loads us. Every label/memory operand is computed relative to this.
ORG 0x7C00

; Emit 16-bit instruction encodings and 16-bit operand sizes (real mode).
[BITS 16]

start16:
    ; cli: block interrupts while segment registers are being reloaded, so
    ; no interrupt can be serviced with a half-configured SS:SP.
    cli
    ; Zero AX (cheapest way to get 0) — it's the source for every
    ; segment register below.
    xor     ax, ax
    ; Stack setup: SS=0 and SP=0x7C00 → stack grows down from linear
    ; address 0x7C00, i.e. just below our own code. PUSH/POP become safe.
    mov     ss, ax
    mov     sp, 0x7C00
    ; Pin DS/ES (and the exotic FS/GS) to paragraph 0 so memory operands
    ; address linear = offset, predictable regardless of BIOS values.
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    ; sti: interrupts are safe again (SS:SP is fully set up), re-enable.
    sti
    ; BIOS enters the boot sector with DL = the boot drive number (0x00
    ; = first floppy). We must remember it: INT 0x13 needs an explicit
    ; drive number and DL may be clobbered later.
    mov     [boot_drv], dl

    ; --- Screen clear --------------------------------------------------
    ; BIOS video service: AH=0x06 = "scroll page up" with AL=0 (fill
    ; value 0 = blank glyph) which is the classic way to clear the screen.
    mov     ax, 0x0600      ; AH=0x06 (scroll up), AL=0x00 (blank fill)
    ; Page attribute used for cleared cells: 0x07 = light grey on black.
    mov     bx, 0x0700      ; BH=0x07 = page number 0 / attribute 0x07
    ; Top-left corner of the scroll window: row 0, col 0.
    mov     cx, 0
    ; Bottom-right corner: DH=0x18 (row 24), DL=0x4F (col 79) = 80x25 page.
    mov     dx, 0x184F
    int     0x10            ; BIOS video interrupt

    ; --- Load the kernel from the floppy -------------------------------
    ; The floppy image layout is:
    ;   sector 1 (LBA/CHS 1)   = this boot sector  (already in memory)
    ;   sector 2 .. 9         = kernel.bin loaded at 0x7E00 (8 sectors,
    ;                            8*512 = 4096 bytes = the 4 KiB kernel)
    ; We deliberately skip the interlinked FAT filesystem — this image is
    ; a raw "floppy", so we read sectors by hand (floppy = 1 side/80 cyl
    ; in the image, but we only use head 0, cyl 0, sectors 2-9).

    ; ES=0 so the destination ES:BX is linear 0x7E00 (just above the
    ; 512-byte boot sector + its guard gap — we don't overwrite ourselves).
    xor     ax, ax
    mov     es, ax
    ; BX = offset within ES where the disk data will land.
    mov     bx, 0x7E00
    ; Drive number = what BIOS gave us at entry, saved earlier.
    mov     dl, [boot_drv]
    ; CHS addressing: cylinder 0 (low 8 bits of the 10-bit cylinder).
    mov     ch, 0
    ; DH = head 0 (floppy image: single side).
    mov     dh, 0
    ; CL = first sector = 2 (CHS sectors are 1-based; sector 1 is ourself,
    ; the kernel physically follows it on the image).
    mov     cl, 2
    ; AH=0x02 = INT 0x13 function "read sectors".
    mov     ah, 0x02
    ; AL=8 = number of sectors to read (= kernel.bin size 4096 bytes).
    mov     al, 8
    int     0x13            ; BIOS disk read
    ; CF set = read error (bad floppy, missing drive, ...) → die loudly.
    jc      .err
    ; BIOS normally returns AL = sectors actually completed. If the
    ; floppy read was short/partial, treat it as fatal too.
    cmp     al, 8
    jne     .err

    ; --- Load the Global Descriptor Table ------------------------------
    ; The GDT must exist BEFORE we flip CR0.PE, because the far jump that
    ; follows loads a selector (0x08) that must resolve through it.
    lgdt    [gdt_desc]      ; load GDTR: [size-1, linear base] (see below)

    ; --- Enable the A20 line --------------------------------------------
    ; In 8086 "unreal" compatibility, address 0x10FFFF wrapped to 0. BIOS
    ; historically disabled A20. Protected mode needs full 32-bit addressing
    ; (video memory at 0xB8000 and code past 0xFFFFF require A20 ON).
    ; INT 0x15 function 0x02401 = "A20 gate ON" (a legacy BIOS service that
    ; manipulates the 9th address bit via the keyboard-encoder trick).
    mov     ax, 0x2401
    int     0x15

    ; --- Switch to protected mode ---------------------------------------
    ; cli again: we're about to change CPU "personality"; an 8086-mode
    ; interrupt here would jump through the old real-mode IVT.
    cli
    ; Read control register CR0 (only via a 32-bit reg in pmode terms).
    mov     eax, cr0
    ; Bit 0 of CR0 = PE (Protection Enable). OR-ing 1 sets it.
    or      eax, 1
    mov     cr0, eax
    ; The CPU is now in 32-bit mode, but CS still has a stale real-mode
    ; base. A FAR JMP with an immediate selector forces a GDT load:
    ; selector 0x08 = our code descriptor, offset 0x7E00 = kernel entry
    ; (the kernel's ORG is 0x7E00 and its descriptor has base 0, so the
    ; linear address matches where we loaded it).
    jmp     0x08:0x7E00

    ; --- Fatal error stop ------------------------------------------------
    ; If the disk read failed there is no point continuing: an endless
    ; HLT keeps the machine frozen in a diagnosable, non-crashing way.
.err:
    cli                     ; no interrupts — we're already wedged
    hlt                     ; CPU sits here forever (halt state)
    jmp     .err            ; belt-and-braces loop-back (unreachable after hlt, but cheap insurance)

; --- The GDT: three 8-byte descriptors, referenced by lgdt ---------------
; Selector format: bits 3..15 = index, bit 1 = table (1 = GDT),
; bits 0..1 = RPL. So selector 0x08 = index 1, 0x10 = index 2.
gdt_start:
    ; Entry 0 — null descriptor: two null DWORDs = 8 bytes. Selector 0x0000
    ; is architecturally reserved (the CPU never loads/validates a null
    ; selector), so its contents are what-have-you; zeros are the norm.
    dd  0, 0

    ; Entry 1 (selector 0x08) — CODE segment: flat, executable, readable, DPL 0.
    ; Descriptor layout (little-endian): limit_low(2) base_low(2) base_mid(1)
    ; access(1) flags|limit_high(1) base_high(1).
    ;   limit 0xFFFF + 0xCF flags (G=4 KiB granularity, D/B=32-bit) -> one
    ;   flat 0..0xFFFFFFFF segment, i.e. any linear address is fetchable.
    ;   access 0x9A = present, code, readable, non-conforming, DPL0.
    dw  0xFFFF, 0
    db  0, 0x9A, 0xCF, 0

    ; Entry 2 (selector 0x10) — DATA segment: flat, writable, DPL 0.
    ;   access 0x92 = present, data, writable, DPL0.
    ; With SS/DS/ES/FS/GS = 0x10 the kernel can touch VGA (0xB8000), its
    ; own code/data (0x7E00..) and BSS (~0x90000) all linearly.
    dw  0xFFFF, 0
    db  0, 0x92, 0xCF, 0
gdt_end:

; Pseudo-descriptor that lgdt consumes: a WORD limit (last valid byte)
; followed by a DWORD linear base. This is memory, NOT a real descriptor.
gdt_desc:
    dw  gdt_end - gdt_start - 1         ; size-1 (limit) of the GDT in bytes
    dd  gdt_start                       ; linear address of the first entry

; Storage for the boot drive number handed to us in DL at BIOS entry.
boot_drv db 0

; --- Pad to the mandatory 512-byte sector -------------------------------
; Pad with zeros up to the last 2 bytes, then write the "boot magic".
; The BIOS checks word 0x1FE == 0xAA55, i.e. bytes 0x55, 0xAA.
times 510-($-$$) db 0
dw  0xAA55
