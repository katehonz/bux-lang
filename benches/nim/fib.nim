## Nim twin of benches/c/fib.c — recursive fib(30)
import std/[times, strformat]

proc fib(n: int): int =
  if n <= 1: return n
  fib(n - 1) + fib(n - 2)

proc nowUs(): int64 =
  int64(epochTime() * 1_000_000.0)

discard fib(20)
let t0 = nowUs()
let r = fib(30)
let t1 = nowUs()
if r < 0: quit(1)
echo &"BENCH fib30 iters=1 total_us={t1 - t0} us_per_op={t1 - t0}"
