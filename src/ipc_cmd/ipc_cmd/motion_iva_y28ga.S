.syntax unified
.arch armv7-a
.fpu neon
.thumb
.text
.align 2
.global motion_iva_boundary
.hidden motion_iva_boundary
.type motion_iva_boundary,%function
.thumb_func
motion_iva_boundary:
    /* Native LR is a working register here. Enter through B.W, preserve it,
     * then return through a separate stack slot. Original instruction loads
     * fp from original sp+40 without altering flags or other registers. */
    sub sp, sp, #8
    push {r0-r12,lr}
    mrs r2, APSR
    vmrs r3, FPSCR
    push {r2,r3}
    vpush {d0-d15}
    vpush {d16-d31}
    ldr r0, [sp,#376]
    ldr r1, [sp,#400]
    ldr r2, [sp,#368]
    str r2, [sp,#308]
    ldr r2, 1f
    ldr r2, [r2]
    str r2, [sp,#320]
    add r2, sp, #264
    bl motion_iva_filter
    vpop {d16-d31}
    vpop {d0-d15}
    pop {r2,r3}
    vmsr FPSCR, r3
    msr APSR_nzcvqg, r2
    pop {r0-r12,lr}
    ldr pc, [sp],#8
.align 2
1: .word motion_iva_resume
.size motion_iva_boundary,.-motion_iva_boundary
.section .note.GNU-stack,"",%progbits
