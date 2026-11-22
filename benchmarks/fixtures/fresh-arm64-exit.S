/* Static Linux ARM64 workload for the matched fresh-lifecycle scenario. */
.text
.globl _start
_start:
    mov x0, #0
    mov x8, #93
    svc #0
