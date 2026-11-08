; =============================================================================
; boot.asm — MyOS Boot Sector (16-bit Real Mode)
; =============================================================================
; This is the very first code the CPU runs when the machine boots.
;
; The BIOS loads the first 512 bytes of the boot device into memory at
; 0x7C00. It only boots if the last two bytes are 0x55 and 0xAA.
;
; What this does:
;   1. Set up segment registers (DS, SS, ES)
;   2. Scroll the screen clear
;   3. Print "Hello, MyOS!" using the BIOS teletype service
;   4. Halt the CPU (infinite loop)
; =============================================================================

ORG 0x7C00              ; Tell NASM: this code loads at 0x7C00

; ------- Entry point -------
start:
    cli                 ; Disable interrupts while we set things up

    ; Set up a proper stack (SS:SP below the boot sector at 0x7C00)
    xor     ax, ax      ; AX = 0
    mov     ss, ax      ; SS = 0
    mov     sp, 0x7C00  ; SP = 0x7C00 (grows downward, away from our code)

    ; Set up data segments
    mov     ds, ax      ; DS = 0
    mov     es, ax      ; ES = 0

    sti                 ; Re-enable interrupts
    cld                 ; Direction flag = forward (string ops go up)

; ------- Clear the screen -------
clear_screen:
    mov     ax, 0x0600  ; AH=06h (scroll up), AL=0 (scroll all rows)
    mov     bx, 0x0700  ; BL=07h (light grey on black attribute)
    mov     cx, 0x0000  ; Top-left corner: row 0, col 0
    mov     dx, 0x184F  ; Bottom-right corner: row 24, col 79
    int     0x10        ; BIOS video interrupt

; ------- Move cursor to top-left (row 0, col 0) -------
set_cursor:
    mov     ah, 0x02    ; BIOS: set cursor position
    mov     bh, 0x00    ; Page 0
    mov     dx, 0x0000  ; Row 0, Column 0
    int     0x10

; ------- Print "Hello, MyOS!" -------
print_hello:
    mov     ah, 0x0E    ; BIOS: teletype output
    mov     bx, 0x0007  ; Page 0, light grey attribute
    mov     si, hello_msg  ; SI points to the string
.next_char:
    lodsb               ; Load byte [SI] into AL, increment SI
    or      al, al      ; Is AL zero? (end of string)
    jz      endless_loop ; If yes, halt
    int     0x10        ; Print character in AL
    jmp     .next_char  ; Repeat for next character

; ------- Halt the CPU -------
endless_loop:
    hlt                 ; Halt until next interrupt
    jmp     endless_loop ; Keep halting forever

; ------- Data -------
hello_msg:
    db "Hello, MyOS!", 13, 10, 0   ; String + CR + LF + null terminator

; ------- Boot signature (must be at bytes 511-512) -------
times 510-($-$$) db 0    ; Pad to 510 bytes with zeros
db 0x55, 0xAA            ; BIOS boot signature
