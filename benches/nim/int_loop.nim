## Nim twin of benches/c/int_loop.c — 1e6 integer arithmetic loop
import std/[times, strformat]

proc nowUs(): int64 =
  int64(epochTime() * 1_000_000.0)

const iters = 1_000_000
var acc = 0
let t0 = nowUs()
for i in 0 ..< iters:
  acc = acc + i * 3 - 1
let t1 = nowUs()
if acc == 0 and iters > 0: quit(1)
let total = t1 - t0
echo &"BENCH int_loop iters={iters} total_us={total} us_per_op={total div iters}"
