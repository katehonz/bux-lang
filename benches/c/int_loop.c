/* C reference: 1e6 integer arithmetic loop */
#include <stdio.h>
#include <stdint.h>
#include <time.h>

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000LL + (int64_t)ts.tv_nsec / 1000LL;
}

int main(void) {
    const int iters = 1000000;
    int acc = 0;
    int64_t t0 = now_us();
    for (int i = 0; i < iters; i++) {
        acc = acc + i * 3 - 1;
    }
    int64_t t1 = now_us();
    if (acc == 0 && iters > 0) return 1;
    printf("BENCH int_loop iters=%d total_us=%lld us_per_op=%lld\n",
           iters, (long long)(t1 - t0), (long long)((t1 - t0) / iters));
    return 0;
}
