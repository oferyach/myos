# MyOS
A simple x86 operating system built from scratch in assembly.

## Project Structure
```
src/
├── boot/        # Bootloader code (real mode, 16-bit)
└── kernel/      # Kernel code (protected mode, 32-bit)
build/           # Assembled binaries & disk images
docs/            # Notes & references
```

## Prerequisites
- NASM 2.16+
- VMware Workstation (or QEMU)
