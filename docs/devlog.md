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

## Session 2 — 2026-11-09
### Step 1: Protected Mode
- Added GDT (Global Descriptor Table) with null, code, and data descriptors
- Added A20 line enable (keyboard controller method)
- Set PE bit in CR0 to switch to protected mode
- Far jump into 32-bit kernel code at 0x7E00
- 32-bit kernel: clears VGA, prints status messages, halts
- VGA print function: takes null-terminated string + color attribute
- **✅ VM boots and shows all status messages in protected mode!**

## Next
- [ ] Set up IDT (Interrupt Descriptor Table)
- [ ] Remap PIC (Programmable Interrupt Controller)
- [ ] Handle keyboard input
- [ ] Add system timer (PIT)
