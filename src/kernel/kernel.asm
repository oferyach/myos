; kernel.asm v44: Fixed kbh scancode table lookup (dirty EAX high bytes broke table indexing)
ORG 0x7E00
[BITS 32]
GDT_C    equ 0x08
GDT_D    equ 0x10
V      equ 0xB8000
KBUF     equ 0x90100
KPOS     equ 0x90120
KREADY   equ 0x90124
CUR      equ 0x90128

k:
    mov ax, GDT_D
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov fs,ax
    mov gs,ax
    mov esp,0x90000
    cli
    mov edi,V
    mov ecx,80*25
    xor eax,eax
    rep stosw
    mov edi,V+2*(80*0+20)
    mov esi,t1
    call p
    ; IDT
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
    ; timer 0x20
    mov eax,timh
    mov edi,idtt+256
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0
    mov byte [edi+5],0x8E
    shr eax,16
    mov word [edi+6],ax
    ; kb 0x21
    mov eax,kbh
    mov edi,idtt+264
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0
    mov byte [edi+5],0x8E
    shr eax,16
    mov word [edi+6],ax
    ; PIC
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
    mov al,0xFC
    out 0x21,al
    mov al,0xFF
    out 0xA1,al
    ; init vars
    mov dword [KPOS], 0
    mov dword [KREADY], 0
    mov dword [CUR], 486
    sti
    ; display prompt
    mov edi, V+2*(80*6+4)
    mov esi, prompt
    call p
.shell:
    cmp dword [KREADY], 0
    jz .shell
    mov dword [KREADY], 0
    call .nln
    cmp byte [KBUF], 0
    jz .prompt
    jmp .proc_cmd
.nln:
    mov eax,[CUR]
    mov ebx,80
    xor edx,edx
    div ebx
    inc eax
    imul eax,80
    add eax,4
    mov [CUR],eax
    cmp dword [CUR],80*25
    jl .nln2
    mov edi,V
    mov ecx,80*24
    mov esi,V+2*80
    rep movsw
    mov ecx,80
    xor eax,eax
    rep stosw
    sub dword [CUR],80
.nln2:
    ret
.proc_cmd:
    mov esi, KBUF
    cmp byte [esi], 'c'
    jne .c2
    cmp byte [esi+1], 'l'
    jne .c2
    cmp byte [esi+2], 's'
    jne .c2
    cmp byte [esi+3], 0
    jne .c2
    mov edi,V
    mov ecx,80*25
    xor eax,eax
    rep stosw
    mov dword [CUR], 4
    jmp .prompt
.c2:
    cmp byte [esi], 'v'
    jne .c3
    cmp byte [esi+1], 'e'
    jne .c3
    cmp byte [esi+2], 'r'
    jne .c3
    cmp byte [esi+3], 0
    jne .c3
    mov edi, [CUR]
    shl edi, 1
    add edi, V
    mov esi, t_ver
    call p
    jmp .next
.c3:
    cmp byte [esi], 'h'
    jne .c4
    cmp byte [esi+1], 'e'
    jne .c4
    cmp byte [esi+2], 'l'
    jne .c4
    cmp byte [esi+3], 'p'
    jne .c4
    cmp byte [esi+4], 0
    jne .c4
    mov edi, [CUR]
    shl edi, 1
    add edi, V
    mov esi, t_help
    call p
    jmp .next
.c4:
    cmp byte [esi], 'r'
    jne .c5
    cmp byte [esi+1], 'e'
    jne .c5
    cmp byte [esi+2], 'b'
    jne .c5
    cmp byte [esi+3], 'o'
    jne .c5
    cmp byte [esi+4], 'o'
    jne .c5
    cmp byte [esi+5], 't'
    jne .c5
    cmp byte [esi+6], 0
    jne .c5
    cli
    jmp k
.c5:
    mov edi, [CUR]
    shl edi, 1
    add edi, V
    mov esi, t_err
    call p
.next:
    mov dword [KPOS], 0
    call .nln
.prompt:
    mov edi, [CUR]
    shl edi, 1
    add edi, V
    mov esi, prompt
    call p
    jmp .shell
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
    mov eax,edi
    sub eax,V
    shr eax,1
    mov [CUR],eax
    popa
    ret
ihand:
    iret
timh:
    mov al,0x20
    out 0x20,al
    iret
kbh:
    pusha
    in al, 0x60
    test al, 0x80
    jnz .kb_eoi
    cmp al, 128
    jae .kb_eoi
    and eax, 0xFF
    mov ebx, sc_tab
    mov al, [ebx+eax]
    test al, al
    jz .kb_eoi
    cmp al, 0x0D
    jz .kb_enter
    cmp al, 0x08
    jz .kb_back
    mov ah, 0x0F
    mov ebx, [CUR]
    shl ebx, 1
    add ebx, V
    mov [ebx], ax
    inc dword [CUR]
    cmp dword [CUR], 80*25
    jl .kb_buf
    mov edi,V
    mov ecx,80*24
    mov esi,V+2*80
    rep movsw
    mov ecx,80
    xor eax,eax
    rep stosw
    sub dword [CUR], 80
.kb_buf:
    cmp dword [KPOS], 32
    jge .kb_eoi
    mov ebx, [KPOS]
    mov [KBUF+ebx], al
    inc dword [KPOS]
    jmp .kb_eoi
.kb_back:
    cmp dword [KPOS], 0
    jz .kb_eoi
    dec dword [KPOS]
    dec dword [CUR]
    mov ax, 0x0F20
    mov ebx, [CUR]
    shl ebx, 1
    add ebx, V
    mov [ebx], ax
    jmp .kb_eoi
.kb_enter:
    mov ebx, [KPOS]
    mov byte [KBUF+ebx], 0
    mov dword [KREADY], 1
    jmp .kb_eoi
.kb_eoi:
    mov al, 0x20
    out 0x20, al
    popa
    iret
idtt:
    times 256*8 db 0
idtp:
    dw 2047
    dd idtt
sc_tab:
    db 0,0,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,0x30,0,0
    db 0x08,0x09,0x71,0x77,0x65,0x72,0x74,0x79,0x75,0x69,0x6F,0x70
    db 0x5B,0x5D,0x0D,0,0x61,0x73,0x64,0x66,0x67,0x68,0x6A,0x6B
    db 0x6C,0x3B,0x27,0x60,0,0x5C,0x7A,0x78,0x63,0x76,0x62,0x6E
    db 0x6D,0x2C,0x2E,0x2F,0,0,0,0x20,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
t1 db "MyOS v44 Shell",0
prompt db "> ",0
t_ver db "MyOS v44",0
t_help db "cls, ver, help, reboot",0
t_err db "Unknown command",0
times 4096-($-$$) db 0