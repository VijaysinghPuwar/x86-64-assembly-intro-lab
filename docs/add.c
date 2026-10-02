/* add.c - C equivalent of src/add.asm, for comparing compiler output with
 * the hand-written version. See docs/compiler-output.md.
 *
 *   gcc -O2 -S -masm=intel -fno-asynchronous-unwind-tables -fcf-protection=none docs/add.c -o -
 */
#include <stdio.h>

static const int num1 = 7;
static const int num2 = 5;

int print_sum(int a, int b)
{
    return printf("%d + %d = %d\n", a, b, a + b);
}

int main(void)
{
    if (print_sum(num1, num2) < 0 || fflush(NULL) != 0) {
        perror("add");
        return 1;
    }
    return 0;
}
