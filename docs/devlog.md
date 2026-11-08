# OS Dev Log
## Session 1 — 2026-11-08
- Set up project at `C:\src\myos`
- Tools: NASM 2.16.03, VMware Workstation, VS Code
- **✅ Boot sector boots successfully in VMware!**

## What We Did
1. Wrote `boot.asm` — 16-bit real-mode boot sector
2. Assembled to `boot.bin` (512 bytes exactly, signature `0x55AA`)
3. Padded to 1.44 MB floppy disk image
4. Created VMware config and booted — saw "Hello, MyOS!"

## Next
- Switch to 32-bit protected mode
- Set up GDT (Global Descriptor Table)
- Enable A20 line
- Load kernel from disk
