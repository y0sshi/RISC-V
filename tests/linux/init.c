/* Minimal freestanding static init for the RV64 Linux early-boot sim.
 *
 * Built with -nostdlib -static so it needs no target libc (the
 * gcc-riscv64-linux-gnu package ships no glibc headers/libs).  It makes the
 * Linux write() syscall directly via `ecall` to print a sentinel line proving
 * the kernel reached userspace, then idles forever (a real init must not exit --
 * that panics the kernel).
 */

static long sys_write(int fd, const char *buf, unsigned long n)
{
    register long a0 asm("a0") = fd;
    register long a1 asm("a1") = (long)buf;
    register long a2 asm("a2") = (long)n;
    register long a7 asm("a7") = 64;        /* __NR_write */
    asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return a0;
}

void _start(void)
{
    static const char msg[] = "LINUX-USERSPACE-OK: init running\n";
    unsigned long len = 0;
    while (msg[len])
        len++;
    sys_write(1, msg, len);
    for (;;)
        asm volatile("" ::: "memory");      /* idle; do not exit */
}
