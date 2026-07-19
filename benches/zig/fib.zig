// Zig twin of benches/c/fib.c — recursive fib(30)
// Build: zig build-exe -OReleaseFast -femit-bin=build/fib fib.zig
const std = @import("std");

fn fib(n: i32) i32 {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

fn nowUs() i64 {
    return @divTrunc(@as(i64, @intCast(std.time.nanoTimestamp())), 1000);
}

pub fn main() !void {
    _ = fib(20);
    const t0 = nowUs();
    const r = fib(30);
    const t1 = nowUs();
    if (r < 0) return error.Unreachable;
    const out = std.io.getStdOut().writer();
    try out.print("BENCH fib30 iters=1 total_us={d} us_per_op={d}\n", .{ t1 - t0, t1 - t0 });
}
