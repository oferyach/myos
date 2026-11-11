; =============================================================================
; boot.asm — Sector 0 (512 bytes), loaded by BIOS at 0x7C00
; =============================================================================
ORG 0x7C00
[BITS 16]

start16:
    cli
    xor     ax, ax
    mov     ss, ax
    mov     sp, 0x7C00
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    sti
    mov     [boot_drv], dl

    ; Clear screen
    mov     ax, 0x0600
    mov     bx, 0x0700
    mov     cx, 0
    mov     dx, 0x184F
    int     0x10

    ; Read kernel: 8 sectors (sectors 2-9) into 0x7E00
    xor     ax, ax
    mov     es, ax
    mov     bx, 0x7E00
    mov     dl, [boot_drv]
    mov     ch, 0
    mov     dh, 0
    mov     cl, 2
    mov     ah, 0x02
    mov     al, 8
    int     0x13
    jc      .err
    cmp     al, 8
    jne     .err

    ; Load GDT
    lgdt    [gdt_desc]

    ; A20
    mov     ax, 0x2401
    int     0x15

    ; Protected mode
    cli
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     0x08:0x7E00

.err:
    cli
    hlt
    jmp     .err

gdt_start:
    dd  0, 0
    dw  0xFFFF, 0
    db  0, 0x9A, 0xCF, 0
    dw  0xFFFF, 0
    db  0, 0x92, 0xCF, 0
gdt_end:
gdt_desc:
    dw  gdt_end - gdt_start - 1
    dd  gdt_start

boot_drv db 0

times 510-($-$$) db 0
dw  0xAA55
