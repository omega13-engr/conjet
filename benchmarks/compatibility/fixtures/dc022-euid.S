/* Linux AArch64 neutral fixture. Exit zero only for the expected effective UID. */
.text
.globl _start
.type _start, %function
_start:
    mov x8, #175      /* geteuid */
    svc #0
    mov x1, #65534
    cmp x0, x1
    cset x0, ne
    mov x8, #93       /* exit */
    svc #0
.size _start, . - _start
