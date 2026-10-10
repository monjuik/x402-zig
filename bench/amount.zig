//! Validation experiments only; production Amount remains unchanged.
const std = @import("std");
const builtin = @import("builtin");
const Amount = @import("x402").Amount;

const lengths = [_]usize{ 1, 4, 6, 7, 15, 16, 17, 20, 31, 32, 33, 78, 128 };
const vector_len = 16;
const samples = 5;
const target_ns = 100 * std.time.ns_per_ms;

fn canonicalPrefix(bytes: []const u8) bool {
    return bytes.len != 0 and (bytes.len == 1 or bytes[0] != '0');
}

fn scalarEarly(bytes: []const u8) bool {
    _ = Amount.parse(bytes) catch return false;
    return true;
}

fn scalarFull(bytes: []const u8) bool {
    if (!canonicalPrefix(bytes)) return false;
    var invalid: u8 = 0;
    for (bytes) |byte| invalid |= @intFromBool((byte -% '0') > 9);
    return invalid == 0;
}

fn vector16(bytes: []const u8) bool {
    if (!canonicalPrefix(bytes)) return false;
    const V = @Vector(vector_len, u8);
    const zero: V = @splat('0');
    const nine: V = @splat(9);
    var offset: usize = 0;
    while (bytes.len - offset >= vector_len) : (offset += vector_len) {
        const block: V = bytes[offset..][0..vector_len].*;
        if (@reduce(.Or, (block -% zero) > nine)) return false;
    }
    for (bytes[offset..]) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

const Variant = enum {
    scalar_early,
    scalar_full,
    vector_16,

    fn validate(comptime self: Variant, bytes: []const u8) bool {
        return switch (self) {
            .scalar_early => scalarEarly(bytes),
            .scalar_full => scalarFull(bytes),
            .vector_16 => vector16(bytes),
        };
    }
};

const Measurement = struct { nanoseconds: i96, checksum: usize };

// The pointer barrier makes input memory opaque on every iteration, preventing
// constant folding and loop-invariant hoisting. All variants share this cost.
noinline fn measure(
    comptime variant: Variant,
    io: std.Io,
    inputs: []const []const u8,
    rounds: usize,
) Measurement {
    var checksum: usize = 0;
    const start = std.Io.Clock.awake.now(io);
    for (0..rounds) |_| {
        for (inputs) |input| {
            std.mem.doNotOptimizeAway(input.ptr);
            const valid = variant.validate(input);
            std.mem.doNotOptimizeAway(valid);
            checksum +%= @intFromBool(valid);
        }
    }
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    std.mem.doNotOptimizeAway(checksum);
    return .{ .nanoseconds = elapsed.toNanoseconds(), .checksum = checksum };
}

fn benchmark(
    comptime variant: Variant,
    io: std.Io,
    writer: *std.Io.Writer,
    name: []const u8,
    inputs: []const []const u8,
) !void {
    _ = measure(variant, io, inputs, 1024); // Warm up before calibration.
    var rounds: usize = 1024;
    while (true) {
        const elapsed = measure(variant, io, inputs, rounds).nanoseconds;
        if (elapsed >= target_ns) break;
        rounds = try std.math.mul(usize, rounds, 2);
    }
    const operations = try std.math.mul(usize, rounds, inputs.len);
    var times: [samples]i96 = undefined;
    var checksum: usize = 0;
    for (&times) |*time| {
        const result = measure(variant, io, inputs, rounds);
        time.* = result.nanoseconds;
        checksum +%= result.checksum;
    }
    std.mem.sort(i96, &times, {}, std.sort.asc(i96));
    const ns_per_op = @as(f64, @floatFromInt(times[samples / 2])) /
        @as(f64, @floatFromInt(operations));
    try writer.print("{s},{s},{d:.3},{d},{d}\n", .{
        name, @tagName(variant), ns_per_op, operations, checksum,
    });
    try writer.flush();
}

fn runCase(io: std.Io, writer: *std.Io.Writer, name: []const u8, inputs: []const []const u8) !void {
    inline for (comptime std.meta.tags(Variant)) |variant| {
        try benchmark(variant, io, writer, name, inputs);
    }
}

pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print("# Zig {s}; target {s}-{s}; CPU {s}; backend {s}; mode {s}; vector width {d}; samples {d}; target {d} ms\n", .{
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        builtin.cpu.model.name,
        @tagName(builtin.zig_backend),
        @tagName(builtin.mode),
        vector_len,
        samples,
        target_ns / std.time.ns_per_ms,
    });
    try writer.writeAll("case,variant,median_ns_per_op,operations_per_sample,checksum\n");
    try runCase(init.io, writer, "empty", &.{""});
    try runCase(init.io, writer, "zero", &.{"0"});
    try runCase(init.io, writer, "leading_zero", &.{"01"});

    var storage: [lengths.len][128]u8 = undefined;
    var mixed: [lengths.len][]const u8 = undefined;
    for (lengths, 0..) |len, index| {
        const bytes = storage[index][0..len];
        for (bytes, 0..) |*byte, offset| byte.* = '1' + @as(u8, @intCast((index + offset) % 9));
        mixed[index] = bytes;
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "valid_{d}", .{len});
        try runCase(init.io, writer, name, &.{bytes});
        const positions = [_]usize{ 0, len / 2, len - 1 };
        for (positions, 0..) |position, p| {
            if (p > 0 and position == positions[p - 1]) continue;
            const original = bytes[position];
            bytes[position] = 'x';
            const invalid_name = try std.fmt.bufPrint(&name_buffer, "invalid_{d}_at_{d}", .{ len, position });
            try runCase(init.io, writer, invalid_name, &.{bytes});
            bytes[position] = original;
        }
    }
    try runCase(init.io, writer, "mixed_valid", &mixed);
}

test "experimental validators match Amount.parse across bytes and block boundaries" {
    var storage: [130]u8 = undefined;
    // Shift by one byte to cover unaligned loads as well as all tail lengths.
    for (0..129) |len| {
        const bytes = storage[1..][0..len];
        @memset(bytes, '1');
        inline for (comptime std.meta.tags(Variant)) |variant| {
            try std.testing.expectEqual(len != 0, variant.validate(bytes));
        }
        for (0..len) |position| {
            for (0..256) |byte| {
                bytes[position] = @intCast(byte);
                const expected = scalarEarly(bytes);
                try std.testing.expectEqual(expected, scalarFull(bytes));
                try std.testing.expectEqual(expected, vector16(bytes));
            }
            bytes[position] = '1';
        }
    }
}
