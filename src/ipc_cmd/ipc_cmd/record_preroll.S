/* SPDX-License-Identifier: GPL-3.0-only */
.syntax unified
.arm
.section .text.creation,"ax",%progbits
.global record_first_frame_time
.type record_first_frame_time,%function
record_first_frame_time:
#if defined(PREROLL_Y623)
    ldr r0, [sp, #96]
    movw ip, #0xb080
    movt ip, #0x7c25
    add ip, ip, r0
    str ip, [r9, #1052]
#elif defined(PREROLL_Y28GA)
    ldr r3, [sp, #60]
    movw ip, #0xb080
    movt ip, #0x7c25
    add ip, ip, r3
    str ip, [r8, #1052]
#endif
    bx lr
.size record_first_frame_time, .-record_first_frame_time
.section .note.GNU-stack,"",%progbits
