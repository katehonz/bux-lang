/* C reference: recursive fib(30) — compare with benches/micro fib30 */
#include <stdio.h>
#include <stdint.h>
#include <time.h>

static int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000LL + (int64_t)ts.tv_nsec / 1000LL;
}

int main(void) {
    (void)fib(20); /* warmup */
    int64_t t0 = now_us();
    int r = fib(30);
    int64_t t1 = now_us();
    if (r < 0) return 1;
    printf("BENCH fib30 iters=1 total_us=%lld us_per_op=%lld\n",
           (long long)(t1 - t0), (long long)(t1 - t0));
    return 0;
}
