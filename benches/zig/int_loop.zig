// Zig twin of benches/c/int_loop.c — 1e6 integer arithmetic loop
// Build: zig build-exe -OReleaseFast -femit-bin=build/int_loop int_loop.zig
const std = @import("std");

fn nowUs() i64 {
    return @divTrunc(@as(i64, @intCast(std.time.nanoTimestamp())), 1000);
}

pub fn main() !void {
    const iters: i32 = 1_000_000;
    var acc: i32 = 0;
    const t0 = nowUs();
    var i: i32 = 0;
    while (i < iters) : (i += 1) {
        acc = acc + i * 3 - 1;
    }
    const t1 = nowUs();
    if (acc == 0 and iters > 0) return error.Unreachable;
    const total = t1 - t0;
    const out = std.io.getStdOut().writer();
    try out.print("BENCH int_loop iters={d} total_us={d} us_per_op={d}\n", .{ iters, total, @divTrunc(total, iters) });
}
