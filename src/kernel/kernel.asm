; kernel.asm v0.9: IDT + PIC remap + timer handler
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
    ; clear
    mov edi,V
    mov cx,80*25
    xor eax,eax
    rep stosw
    ; title
    mov edi,V+2*(80*0+20)
    mov esi,t1
    call p
    ; IDT - fill all with default handler
    mov edi,idtt
    mov cx,256
.il:
    mov eax,ihand
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0x8E
    shr eax,16
    mov word [edi+5],ax
    add edi,8
    loop .il
    ; install timer handler at entry 0x20
    mov eax,timh
    mov edi,idtt+256
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0x8E
    shr eax,16
    mov word [edi+5],ax
    lidt [idtp]
    ; msg2
    mov edi,V+2*(80*2+4)
    mov esi,t2
    call p
    ; PIC remap
    mov al,0x11
    out 0x20,al
    nop
    mov al,0x11
    out 0xA0,al
    nop
    mov al,0x20
    out 0x21,al
    nop
    mov al,0x28
    out 0xA1,al
    nop
    mov al,4
    out 0x21,al
    nop
    mov al,2
    out 0xA1,al
    nop
    mov al,0x01
    out 0x21,al
    nop
    mov al,0x01
    out 0xA1,al
    nop
    ; mask all except IRQ0
    mov al,0xFE
    out 0x21,al
    nop
    mov al,0xFF
    out 0xA1,al
    nop
    ; sti
    sti
    ; msg3
    mov edi,V+2*(80*4+4)
    mov esi,t3
    call p
    ; idle - timer will wake us
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
; default handler
ihand:
    iret
; timer handler - send EOI and return
timh:
    mov al,0x20
    out 0x20,al
    iret
idtt:
    times 256*8 db 0
idtp:
    dw 2047
    dd idtt
t1 db "MyOS v0.9 TEST",0
t2 db "IDT+PIC+timer",0
t3 db "Timer running",0
times 4096-($-$$) db 0
