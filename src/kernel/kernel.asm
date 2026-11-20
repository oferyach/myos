; kernel.asm v44: Fixed kbh scancode table lookup (dirty EAX high bytes broke table indexing)
; =============================================================================
; kernel.asm — STAGE 2: the 32-bit protected-mode kernel (exactly 4 KiB)
; -----------------------------------------------------------------------------
; Loaded by boot.asm at linear 0x7E00 (the 8 floppy sectors right behind the
; boot sector) and entered via the far jump `jmp 0x08:0x7E00`.
;
; Overall flow:
;   1. set flat segment registers + a fresh stack
;   2. blank the 80x25 VGA text page, print a banner
;   3. build a full 256-entry IDT (default = no-op IRET gate), then install
;      real handlers for INT 0x20 (PIT timer) and INT 0x21 (keyboard)
;   4. reprogram the PIC so IRQ0->INT 0x20, IRQ1->INT 0x21
;   5. run an eternal read-eval shell loop:
;        typed chars are echoed and buffered by the keyboard IRQ; Enter sets
;        KREADY, and the main loop matches the line against built-ins:
;        cls / ver / help / reboot.
;
; Fixed-point memory map (all segments are flat 4 GiB, so linear == offset):
;   0x7C00   boot sector (still resident, never executed again)
;   0x7E00   this kernel: code, then data/strings at the tail
;   0x90000  stack top (grows downward)
;   0x90100  KBUF   — one input line, max 31 chars + NUL terminator
;   0x90120  KPOS   — dword: how many chars are buffered
;   0x90124  KREADY — dword: 1 = a full line is waiting for the shell
;   0x90128  CUR    — dword: screen cursor, counted in CELLS (0..1999)
;   0x9012C  CURCELL  — dword: cell where the blink-cursor underscore sits
;   0xB8000  VGA text page: one WORD per cell = glyph (low) + attr (high)
; ============================================================================
ORG 0x7E00
[BITS 32]
; --- Segment selectors & layout constants -------------------------------
; GDT_C / GDT_D must match boot.asm's GDT exactly: index 1 = flat CODE
; selector (kernel code runs through it), index 2 = flat DATA selector
; (data, stack and video accesses all go through it).
; V = the VGA text-mode framebuffer: 80 columns x 25 rows of 16-bit cells
; (low byte = CP437 glyph, high byte = colour attribute).
; KBUF/KPOS/KREADY/CUR are this kernel's "BSS": plain RAM addresses just
; above the code, initialized at runtime (the file itself never carries
; any nonzero bytes there — the floppy load leaves whatever, and the
; startup code writes the real initial values).
GDT_C    equ 0x08
GDT_D    equ 0x10
V      equ 0xB8000
KBUF     equ 0x90100
KPOS     equ 0x90120
KREADY   equ 0x90124
CUR      equ 0x90128
; CURCELL is the 'BSS' slot right after CUR: the cell index where the blinking
; underscore cursor is currently drawn (see tc() below for how it is tracked)
CURCELL  equ 0x9012C

; ============================================================================
; KERNEL ENTRY — reached from boot.asm as `jmp 0x08:0x7E00` (CS = GDT_C
; already loaded; CPU is in 32-bit protected mode, DPL 0, flat memory).
; The block below:
;   * points DS/ES/SS/FS/GS at the flat data selector and sets ESP = 0x90000
;     (a fresh stack in the empty region above the kernel image),
;   * CLI: interrupts are blocked until the IDT is fully installed — any
;     interrupt with no valid gate would triple-fault and reboot the VM,
;   * REP STOSW paints all 80*25=2000 WORD cells with 0x0000 (NUL glyph,
;     attribute 0) = the whole blank screen,
;   * prints the banner string t1 at row 0, column 20 (roughly centred)
;     by CALLing p() — see p() further down for its calling convention.
; ============================================================================
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
; --- Build the complete IDT (256 gates x 8 bytes = 2 KiB) ---------------
; Every gate is first pointed at `ihand`, a bare IRET: any exception or
; interrupt that was never customized is then a silent no-op (IRET pops
; back exactly what the CPU pushed) instead of a triple fault. Gate
; encoding (little-endian):
;   bytes 0..1 = handler offset bits  0..15
;   bytes 2..3 = code segment selector (0x08 -> our flat kernel CS)
;   byte  4    = reserved, must be 0
;   byte  5    = P(1) | DPL(00) | type nibble (0x8E = present, DPL 0)
;   bytes 6..7 = handler offset bits 16..31
; EDI walks the table, ECX = 256 is the loop counter.
    ; IDT
    mov edi,idtt
    mov ecx,256
; Per gate: low half of the handler offset in AX, selector GDT_C, reserved
; 0, flags 0x8E, high half 0 (ihand sits within the first 64 KiB of the
; segment). ADD EDI,8 advances to the next gate; LOOP = legacy CX--/JNZ.
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
; --- Replace gate 0x20 (idtt + 0x20*8 = idtt+256) with the timer handler --
; timh's full 32-bit offset is written in two halves: LOW 16 into bytes
; 0..1 and, after SHR 16, the HIGH 16 into bytes 6..7. Same selector/flags
; as the default gates.
    ; timer 0x20
    mov eax,timh
    mov edi,idtt+256
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0
    mov byte [edi+5],0x8E
    shr eax,16
    mov word [edi+6],ax
; --- Likewise for gate 0x21 (idtt + 0x21*8 = idtt+264) = keyboard handler
    ; kb 0x21
    mov eax,kbh
    mov edi,idtt+264
    mov word [edi],ax
    mov word [edi+2],GDT_C
    mov byte [edi+4],0
    mov byte [edi+5],0x8E
    shr eax,16
    mov word [edi+6],ax
; --- Reprogram the 8259/286 PIC (interrupt numbering) --------------------
; As configured by BIOS, hardware IRQs 0..7 raise INT 0..7 — colliding with
; the CPU's own exceptions (divide error = 0, single-step = 1, ...). The
; classic PC trick re-maps the PIC so IRQ0..7 raise INT 0x20..0x27; then
; IRQ0 (the 18.1 Hz PIT timer) hits our gate 0x20 (timh) and IRQ1
; (keyboard) hits gate 0x21 (kbh).
; Ports used:
;   0x20 = IMR  (Interrupt Mask Register: which IRQs are ignored)
;   0xA0 = IMR *latch*: readable but not writable directly; writing the
;        latch port retargets subsequent IMR reads/writes (286 trick)
;   0x21 = legacy control port: after ICW1 it takes ICW2/3/4 (later IMR)
;   0xA1 = AT control port: writing it starts a PIC reset + ICW1
; The paired OUTs below walk the PIC through that reset/ICW dance (the
; quirky-but-proven sequence; net effect = base 0x20, timer+keyboard live).
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
; --- Initialize the shell state ---------------------------------------
; KPOS=0: empty input line buffer.  KREADY=0: idle until first Enter.
; CUR=486 = row 6 (6*80) + column 6 — the cell immediately right of the
; "> " prompt about to be drawn at row 6 col 4.
; STI: re-enable interrupts — the IDT is complete, so timer/keyboard IRQs
; may land on our gates at any instruction boundary from here on.
    ; init vars
    mov dword [KPOS], 0
    mov dword [KREADY], 0
    mov dword [CUR], 486
    sti
; Draw the prompt "> " at row 6, col 4. Byte address = V + 2*(row*80+col)
; — the factor 2 because every text cell is a WORD (glyph+attribute).
; p() also recomputes CUR to point just past what was printed.
    ; display prompt
; Draw the blinking cursor at CUR (cell just past the banner). tc() remembers
; this position in CURCELL and erases the old cell when it was not overwritten
    call tc
    mov edi, V+2*(80*6+4)
    mov esi, prompt
    call p
; ============================================================================
; SHELL MAIN LOOP — the program never "exits" (only reboot restarts kernel)
; The keyboard IRQ cannot CALL our parser directly, so IRQ and main program
; communicate through the memory flags at 0x90120..0x90128: kbh raises
; KREADY on Enter and we busy-spin here until it is nonzero.
; Then: consume KREADY, call .nln (move CUR to the next line, scroll if
; needed), and if the buffered line is empty (KBUF[0] == NUL — an Enter-only
; line) skip straight to redrawing the prompt; otherwise parse it.
; ============================================================================
.shell:
    cmp dword [KREADY], 0
    jz .shell
    mov dword [KREADY], 0
    call .nln
    cmp byte [KBUF], 0
    jz .prompt
    jmp .proc_cmd
; --- .nln: move CUR to (row+1, column 4); scroll the page if it was
; already the bottom line ---------------------------------------------------
; Integer math: DIV 80 (EDX zeroed -> unsigned, remainder thrown away)
; gives the row in EAX; +1 row; IMUL 80 back to a cell index; +4 indent.
; If CUR >= 80*25 = 2000 the whole page is full: scroll up by copying rows
; 2..25 one row up (REP MOVSW, 80*24 WORDs, source V+160 i.e. V+2*80) then
; paint the now-duplicated bottom row blank (REP STOSW, 80 WORDs of 0), and
; finally CUR -= 80 so the cursor visually follows its text up one row.
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
; Both paths (no-scroll and after-scroll) converge at this return label.
.nln2:
; CUR moved to the next line here (scroll included): tc() erases the old
; cursor cell (a plain blank) and draws the underscore at the new CUR
    call tc
    ret
; ============================================================================
; COMMAND DISPATCH — the consumed line sits at KBUF as a C string; each
; built-in is matched char-by-char: CMP BYTE [ESI+n], char / JNE next.
; A NUL in the pattern position must line up with the line's NUL so "clsx"
; does not match "cls".
; BUILT-IN #1 'cls': clear the whole page (REP STOSW of 2000 zero WORDs)
; and set CUR=4 = row 0, col 4 — the new top-of-page indent.
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
; cls: the REP STOSW already blanked everything; tc() paints the new cursor
; at row 0 col 4 (its erase of the old cell is a harmless no-op on a blank
; page, since the clear covered it)
    call tc
    jmp .prompt
; BUILT-IN #2 'ver': print t_ver ("MyOS v44") at the current cursor.
; Byte address = V + CUR*2 (SHL 1), then p() does the printing.
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
; BUILT-IN #3 'help': print t_ver's sibling t_help (list of built-ins)
; at the cursor, same addressing trick.
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
; BUILT-IN #4 'reboot': CLI then jump straight back to the kernel entry
; `k:` — a cold restart of the whole kernel (banner, IDT, PIC, screen all
; rebuilt), no BIOS involved at all.
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
; NO built-in matched: print t_err ("Unknown command") at the cursor
; (CUR*2 + V again), then fall through to the shared post-command tail.
.c5:
    mov edi, [CUR]
    shl edi, 1
    add edi, V
    mov esi, t_err
    call p
; --- Post-command epilogue ----------------------------------------------
; Discard the consumed line (KPOS=0; the next typed char overwrites slot 0),
; advance to the next line via .nln (with auto-scroll)...
.next:
    mov dword [KPOS], 0
    call .nln
; ...then redraw the prompt at the new CUR and jump back to .shell, which
; waits for the next Enter. (Loop: shell <-> keyboard IRQ via KREADY/KBUF.)
.prompt:
    mov edi, [CUR]
    shl edi, 1
    add edi, V
    mov esi, prompt
    call p
    jmp .shell
; ============================================================================
; p() — string print subroutine, CALLed (RET on return, stack used for the
; return address).
;   IN  : ESI = NUL-terminated ASCII string; EDI = byte address in VGA page
;   DOES: writes one WORD per char — glyph in AL, colour attribute AH=0x0F
;         (light grey on black) — advancing one cell (2 bytes) per char
;   SIDE: stores global CUR = cell just past the printed text, so the shell
;         knows where the cursor ended up (used by .nln and command echo)
; PUSHAD/POPAD keep every caller register intact across the call.
; ============================================================================
p:
    pusha
; Char-at-a-time loop: load [ESI]; zero = end of string -> .pd; otherwise
; synthesize WORD glyph+attr 0x0F, store at EDI, step EDI by one cell (2
; bytes) and ESI by one byte, repeat.
.p1:
    mov al,[esi]
    test al,al
    jz .pd
    mov ah,0x0F
    mov [edi],ax
    add edi,2
    inc esi
    jmp .p1
; String finished: derive the new CUR from the final EDI: subtract the
; frame-buffer base, then SHR 1 converts BYTE span -> CELL count.
.pd:
    mov eax,edi
    sub eax,V
    shr eax,1
; p() rule: the printed text itself already covered the old cursor cell (it
; started printing AT the cursor), so re-anchor CURCELL to the new CUR and
; tc() below will just redraw the underscore at the new position
    mov [CURCELL],eax
    mov [CUR],eax
    call tc
    popa
    ret

; ============================================================================
; tc() - draw/track the BLINKING cursor (CALLed wherever CUR ended up moving:
; startup, end of p(), end of .nln, cls, and kbh exit)
; ---------------------------------------------------------------------------
; The cursor is a normal text cell painted with an underscore (CP437 glyph
; 0x5F) and attribute 0x8F: bit 7 of the attribute is the VGA text-mode
; HARDWARE BLINK bit, so the display itself flashes every ~100 ms blink cell
; (real 8086/286 hardware AND VMware) - no timer-handler bookkeeping needed,
; and timh stays exactly as it was.
;
; CURCELL remembers where the underscore currently lives:
;   CURCELL != CUR : the old cell was NOT overwritten by anything -> repaint
;                    it as a plain space (0x0F20) FIRST, then draw the new
;                    cell. This is what kills the ghost cursors people saw
;                    after Enter / new-line / full-screen scrolls.
;   CURCELL == CUR : in-place redraw only (cursor just re-blinks).
; Position correctness everywhere follows from the invariant that the cell
; AT CUR is always blank, and every mutation either overwrites the old
; cursor cell with its own output (echo, command printing, backspace blank,
; cls clear, scroll copy) or lands the cursor on a fresh blank cell.
; PUSHAD/POPAD: callable from anywhere, including from inside kbh itself.
; ============================================================================
tc:
    pusha
    mov ebx, [CURCELL]
    cmp ebx, [CUR]
    je .tc_draw
    cmp ebx, 80*25
    jge .tc_draw
    shl ebx, 1
    add ebx, V
    mov word [ebx], 0x0F20
.tc_draw:
    mov ebx, [CUR]
    cmp ebx, 80*25
    jl .tc_ok
    mov ebx, 80*25-1
.tc_ok:
    mov [CURCELL], ebx
    shl ebx, 1
    add ebx, V
    mov word [ebx], 0x8F5F
    popa
    ret
; --- The 256 default IDT gates' target: a bare IRET ----------------------
; Any interrupt/exception never overridden below lands here: IRET pops the
; very return address the CPU pushed on entry, so the interrupt is a
; perfectly silent no-op. Without this, any stray exception (e.g. a GP
; fault) would double/triple-fault and reboot the VM.
ihand:
    iret
; --- INT 0x20 = PIT timer handler -----------------------------------------
; The ONLY thing the timer handler must do is ACKnowledge the IRQ: OUT
; 0x20, 0x20 writes the ACK byte to the PIC latch. Without an ACK the PIC
; believes IRQ0 is still in progress and will NEVER raise IRQ1 again —
; i.e. forgetting this freezes the keyboard. IRET returns to the spin loop
; (which is usually .shell's busy-wait; that's why the timer must do no
; more than ACK).
timh:
    mov al,0x20
    out 0x20,al
    iret
; ============================================================================
; INT 0x21 = KEYBOARD HANDLER — the heart of input: read the raw scancode
; from the 8042-style keyboard port, translate to ASCII, ECHO it onto the
; screen at CUR, BUFFER it in KBUF, and on Enter signal the shell via KREADY.
; PUSHAD first (and POPAD at .kb_eoi) so the shell program's own registers
; survive the interrupt, exactly like p() does for CALLs.
; ============================================================================
kbh:
    pusha
; IN from port 0x60 returns the key's scancode (set 1):
;   bit 7 set  = "key RELEASE" code -> ignored (presses only, otherwise
;                every key would type twice: press + release).
; Codes >= 128 (extended/prefixed keys) get a second guard and are dropped
; too (bit-7 test above already covers plain releases; this catches the
; extended set's high codes before they could index the table).
    in al, 0x60
    test al, 0x80
    jnz .kb_eoi
    cmp al, 128
    jae .kb_eoi
; ---- THE v44 FIX (see file header comment) ------------------------------
; IN only fills AL; the UPPER 24 bits of EAX still contain garbage from
; whatever ran earlier in the handler. The table lookup below indexes with
; the FULL EAX (EBX+EAX), so dirty high bytes read random memory instead
; of sc_tab — the previous versions' "random junk chars" bug. Mask EAX
; to a clean scancode before any indexing.
    and eax, 0xFF
; Translate raw scancode -> ASCII glyph via sc_tab (see the table at the
; bottom of the file; index = scancode, value 0 = "ignore this key").
    mov ebx, sc_tab
    mov al, [ebx+eax]
    test al, al
    jz .kb_eoi
; Special translated codes:
;   0x0D (Enter/CR)  -> branch .kb_enter: finalize the buffered line
;   0x08 (Backspace) -> branch .kb_back: erase last echo + last buffer slot
;   anything else    -> ordinary printable: fall through to ECHO below.
; ECHO: compose the VGA WORD (glyph AL + attribute AH=0x0F white-on-black),
; address = V + CUR*2 (SHL 1 then ADD V), store it, and bump CUR. If the
; page is full (CUR >= 80*25) perform the same scroll-up routine as .nln
; (shift rows up, blank bottom line, CUR -= 80).
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
; Echo wrote the char INTO the old cursor cell, so the underscore is gone by
; itself; just move CURCELL along so the tc() at kbh exit skips the erase
    mov ebx, [CUR]
    mov [CURCELL], ebx
    cmp dword [CUR], 80*25
    jl .kb_buf
; (Scroll branch entered only when CUR overflowed the page — identical
; logic to .nln's scroll; it could be a CALL, kept inline for simplicity.)
    mov edi,V
    mov ecx,80*24
    mov esi,V+2*80
    rep movsw
    mov ecx,80
    xor eax,eax
    rep stosw
    sub dword [CUR], 80
; Full-page scroll (kbh path): the scrolled copy/blank pass already handled
; the old cursor cell; re-anchor CURCELL to the post-scroll CUR
    mov ebx, [CUR]
    mov [CURCELL], ebx
; Buffer append: KPOS < 32 caps the input line at 31 chars (the 32nd slot
; is reserved for the NUL .kb_enter writes); once full, extra typed chars
; are still echoed on screen but simply not remembered (jge .kb_eoi).
.kb_buf:
    cmp dword [KPOS], 32
    jge .kb_eoi
    mov ebx, [KPOS]
    mov [KBUF+ebx], al
    inc dword [KPOS]
    jmp .kb_eoi
; Backspace: only if the line has content (KPOS>0): shrink KPOS, retract
; CUR (the echoed cursor), and paint a space (0x20 with attribute 0x0F ->
; WORD 0x0F20) over the cell just before the cursor so the echo visually
; erases. Screen echo and input buffer stay in lockstep.
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
; Enter: terminate the buffered line with NUL at KBUF[KPOS] (so the
; shell's char-by-char matching sees a C string) and raise KREADY=1, which
; wakes .shell's busy-wait to come parse it.
.kb_enter:
    mov ebx, [KPOS]
    mov byte [KBUF+ebx], 0
    mov dword [KREADY], 1
    jmp .kb_eoi
; Common exit path for every keyboard case: ACK the PIC (OUT 0x20,0x20 —
; again: without ACK, IRQ1 never fires a second time and typing freezes),
; POPAD restores the shell program's registers, IRET returns to the
; instruction the shell was spinning on.
.kb_eoi:
; Redraw/track the blinking cursor after this keyboard event: usually same
; cell = redraw in place; after backspace the old underscore cell is erased
; and drawn back one column (echo/scroll already fixed CURCELL above)
    call tc
    mov al, 0x20
    out 0x20, al
    popa
    iret
; --- Static data tables -----------------------------------------------------
; idtt: the raw IDT itself, 2048 zero bytes = 256 placeholder gates. The
; kernel overwrites all gates at startup (see the IDT build above); the
; zeros exist so the table has a fixed size and location in the image.
idtt:
    times 256*8 db 0
; idtp: the pseudo-descriptor lidt consumes: WORD limit (2047 = last valid
; byte index) + DWORD linear base — exactly the same shape as boot.asm's
; gdt_desc, just for the IDT.
idtp:
    dw 2047
    dd idtt
; sc_tab: scancode-set-1 -> ASCII map (index = scancode, 128 bytes).
; Only unshifted glyphs are covered: digits, qwerty letters, a few specials
; (brackets, semicolon, quote, backtick, backslash, comma/dot/slash, space),
; Enter (scancode 0x1C) -> 0x0D, Backspace (0x0E) -> 0x08, Tab -> 0x09.
; Unused keys = 0 = dropped by `test al,al / jz .kb_eoi`. The line breaks
; are visual only — the table is one continuous array; v44's whole point
; was that indexing it needed a CLEAN EAX.
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
; --- NUL-terminated message strings for p() -------------------------------
; CP437/ASCII bytes; p() stops at the first 0.
t1 db "MyOS v44 Shell",0
prompt db "> ",0
t_ver db "MyOS v44",0
t_help db "cls, ver, help, reboot",0
t_err db "Unknown command",0
; Pad kernel.bin to exactly 4096 bytes = 8 sectors, which must match the
; boot sector's read (AL=8 sectors at 0x7E00) — keep this >= the real code
; size whenever the kernel grows, and keep ORG 0x7E00 + 4 KiB below the
; 640 KiB conventional-memory ceiling.
times 4096-($-$$) db 0
