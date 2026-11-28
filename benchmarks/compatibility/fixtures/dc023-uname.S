/* Linux AArch64 neutral fixture. Report the kernel's uname result by exit code. */
.text
.globl _start
.type _start, %function
_start:
    sub sp, sp, #400  /* Space for Linux's bounded utsname result. */
    mov x0, sp
    mov x8, #160     /* uname */
    svc #0
    cmp x0, #0
    b.eq .Lexit
    cmn x0, #1       /* -EPERM */
    mov x0, #41
    b.ne .Lexit
    mov x0, #40
.Lexit:
    mov x8, #93      /* exit */
    svc #0
.size _start, . - _start
