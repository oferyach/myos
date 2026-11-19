; kernel.asm v36: IDT + sti + timer handler (remapped IRQ0)
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
    cli
    ; clear screen
    mov edi,V
    mov ecx,80*25
    xor eax,eax
    rep stosw
    ; title
    mov edi,V+2*(80*0+20)
    mov esi,t1
    call p
    ; IDT fill
    mov edi,idtt
    mov ecx,256
.il:
    mov ax,ihand
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0
    mov byte [edi+5],0x8E
    mov word [edi+6],0
    add edi,8
    loop .il
    lidt [idtp]
    ; timer handler at 0x20
    mov eax,timh
    mov edi,idtt+256
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0
    mov byte [edi+5],0x8E
    shr eax,16
    mov word [edi+6],ax
    ; PIC init
    mov al,0x11
    out 0x20,al
    out 0xA0,al
    mov al,0x20
    out 0x21,al
    mov al,0x28
    out 0xA1,al
    mov al,0x04
    out 0x21,al
    mov al,0x02
    out 0xA1,al
    mov al,0x01
    out 0x21,al
    mov al,0x01
    out 0xA1,al
    ; unmask IRQ0
    mov al,0xFE
    out 0x21,al
    mov al,0xFF
    out 0xA1,al
    sti
    ; display
    mov edi,V+2*(80*2+4)
    mov esi,t2
    call p
    mov edi,V+2*(80*4+4)
    mov esi,t3
    call p
.hl:
    jmp .hl
p:
    pusha
.p1:
    mov al,[esi]
    test al,al
    jz .pd
    mov ah,0x0F
    mov word [edi],ax
    add edi,2
    inc esi
    jmp .p1
.pd:
    popa
    ret
ihand:
    iret
timh:
    mov al,0x20
    out 0x20,al
    iret
idtt:
    times 256*8 db 0
idtp:
    dw 2047
    dd idtt
t1 db "MyOS v36 TEST",0
t2 db "IDT+sti OK",0
t3 db "Stable",0
times 4096-($-$$) db 0