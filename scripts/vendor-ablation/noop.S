/* ARM Linux EABI: no libc, loader, allocation, threads or network syscalls. */
.syntax unified
.arm
.global _start
.section .text
_start:
    mov r0, #0
    mov r7, #1
    svc #0
.section .note.GNU-stack,"",%progbits
