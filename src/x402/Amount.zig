//! Decimal amount in atomic token units.
//! Construct through parse().

pub const std = @import("std");
pub const Amount = @This();

bytes: []const u8,

/// Parses amount.
/// Input memory must remain valid and unchanged while the amount is used.
pub fn parse(bytes: []const u8) error{InvalidAmount}!Amount {
    if (bytes.len == 0)
        return error.InvalidAmount;

    if (bytes.len > 1 and bytes[0] == '0')
        return error.InvalidAmount;

    for (bytes) |byte| {
        if (byte < '0' or byte > '9')
            return error.InvalidAmount;
    }
    return .{ .bytes = bytes };
}

/// Compares amounts numerically.
pub fn order(self: Amount, other: Amount) std.math.Order {
    return switch (std.math.order(self.bytes.len, other.bytes.len)) {
        .eq => std.mem.order(u8, self.bytes, other.bytes),
        .lt => .lt,
        .gt => .gt,
    };
}

pub fn jsonStringify(self: Amount, jw: anytype) !void {
    try jw.write(self.bytes);
}

test "parse accepts canonical amounts and borrows input" {
    const cases = [_][]const u8{
        "0",
        "1",
        "1000",
        "18446744073709551616", // Greater than maxInt(u64).
    };

    for (cases) |input| {
        const amount = try Amount.parse(input);
        try std.testing.expectEqualStrings(input, amount.bytes);
        try std.testing.expect(input.ptr == amount.bytes.ptr);
    }
}

test "parse rejects non-canonical amounts" {
    const cases = [_][]const u8{
        "",
        "00",
        "01",
        "+1",
        "-1",
        "1.0",
        "1e6",
        " 1",
        "1 ",
        "1\n",
        "a12",
        "1a2",
        "12a",
        "١",
    };

    for (cases) |input| {
        try std.testing.expectError(
            error.InvalidAmount,
            Amount.parse(input),
        );
    }
}

test "order compares canonical amounts numerically" {
    const cases = .{
        .{ "0", "0", .eq },
        .{ "0", "1", .lt },
        .{ "1", "0", .gt },
        .{ "1000", "1000", .eq },
        .{ "9", "10", .lt },
        .{ "10", "9", .gt },
        .{ "123", "124", .lt },
        .{ "124", "123", .gt },
        .{ "199", "200", .lt },
        .{ "18446744073709551616", "18446744073709551617", .lt },
        .{ "18446744073709551616", "9999999999999999999", .gt },
    };

    inline for (cases) |case| {
        const lhs = try Amount.parse(case[0]);
        const rhs = try Amount.parse(case[1]);
        const expected: std.math.Order = case[2];
        try std.testing.expectEqual(expected, lhs.order(rhs));
    }
}

test "jsonStringify writes amounts as JSON strings" {
    const cases = .{
        .{ "0", "\"0\"" },
        .{ "1000", "\"1000\"" },
        .{ "18446744073709551616", "\"18446744073709551616\"" },
    };

    inline for (cases) |case| {
        const amount = try Amount.parse(case[0]);

        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        try std.json.Stringify.value(amount, .{}, &writer);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}
