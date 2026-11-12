; kernel.asm v11: IDT + sti + timer handler (no PIC)
ORG 0x7E00
[BITS 32]
GDT_C    equ 0x08
GDT_D    equ 0x10
V      equ 0xB8000

k:
    mov ax, GDT_D
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov fs,ax
    mov gs,ax
    mov esp,0x90000
    mov edi,V
    mov cx,80*25
    xor eax,eax
    rep stosw
    mov edi,V+2*(80*0+20)
    mov esi,t1
    call p
    mov edi,idtt
    mov cx,256
.il:
    mov ax,ihand
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0x8E
    mov word [edi+5],0
    add edi,8
    loop .il
    lidt [idtp]
    mov edi,V+2*(80*2+4)
    mov esi,t2
    call p
    mov al,0xFF
    out 0x21,al
    nop
    mov al,0xFF
    out 0xA1,al
    nop
    sti
    mov edi,V+2*(80*4+4)
    mov esi,t3
    call p
.hl:
    hlt
    jmp .hl
p:
    pusha
.p1:
    mov al,[esi]
    test al,al
    jz .pd
    mov ah,0x0F
    mov [edi],ax
    add edi,2
    inc esi
    jmp .p1
.pd:
    popa
    ret
ihand:
    iret
idtt:
    times 256*8 db 0
idtp:
    dw 2047
    dd idtt
t1 db "MyOS v11 TEST",0
t2 db "IDT+sti OK",0
t3 db "Stable",0
times 4096-($-$$) db 0
