//! An object describing the payment verification result.
//!
//! Specification: x402 v2, 5.4.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions and extra borrow caller-owned memory,
//! which must remain valid while the result is in use.

const std = @import("std");
const json_limits = @import("json_limits.zig");

const VerifyResponse = @This();

// Fields.

/// Indicates whether the payment authorization is valid.
is_valid: bool,

/// Reason for invalidity (omitted if valid).
invalid_reason: ?[]const u8 = null,

/// Address of the payer’s wallet.
payer: ?[]const u8 = null,

/// Protocol extensions data.
extensions: ?std.json.ObjectMap = null,

/// Scheme-specific additional data.
extra: ?std.json.ObjectMap = null,

pub const LimitError = error{
    InvalidReasonTooLong,
    PayerTooLong,
    TooManyExtensions,
    ExtensionsTooLong,
    ExtraTooLong,
};

///  Library default limits for collection counts and decoded UTF-8 string bytes.
pub const Limits = struct {
    max_invalid_reason_bytes: usize = 4096,
    max_payer_bytes: usize = 256,
    max_extensions: usize = 16,

    /// Maximum total UTF-8 bytes of decoded keys and values in extensions.
    max_extensions_string_bytes: usize = 16 * 1024,

    /// Maximum total UTF-8 bytes of decoded keys and values in extra.
    max_extra_string_bytes: usize = 4096,

    /// Maximum byte length for all decoded string values and keys.
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = limits.max_invalid_reason_bytes;
        total = try std.math.add(usize, total, limits.max_payer_bytes);

        if (limits.max_extensions > 0) {
            total = try std.math.add(usize, total, limits.max_extensions_string_bytes);
        }

        total = try std.math.add(usize, total, limits.max_extra_string_bytes);

        return total;
    }

    /// Checks decoded string sizes against the limits.
    pub fn check(limits: Limits, response: VerifyResponse) LimitError!void {
        if (response.invalid_reason) |reason| {
            if (reason.len > limits.max_invalid_reason_bytes)
                return error.InvalidReasonTooLong;
        }

        if (response.payer) |payer| {
            if (payer.len > limits.max_payer_bytes)
                return error.PayerTooLong;
        }

        if (response.extensions) |extensions| {
            if (extensions.count() > limits.max_extensions)
                return error.TooManyExtensions;

            json_limits.checkStringBytes(
                .{ .object = extensions },
                limits.max_extensions_string_bytes,
            ) catch return LimitError.ExtensionsTooLong;
        }

        if (response.extra) |extra| {
            json_limits.checkStringBytes(
                .{ .object = extra },
                limits.max_extra_string_bytes,
            ) catch return LimitError.ExtraTooLong;
        }
    }
};

test "Limits.maxStringBytes handles custom limits and overflow" {
    var limits: Limits = .{
        .max_invalid_reason_bytes = 1,
        .max_payer_bytes = 2,
        .max_extensions = 2,
        .max_extensions_string_bytes = 3,
        .max_extra_string_bytes = 4,
    };
    try std.testing.expectEqual(@as(usize, 10), try limits.maxStringBytes());

    const max = std.math.maxInt(usize);

    // Disabled extensions do not contribute to the budget.
    limits.max_extensions = 0;
    limits.max_extensions_string_bytes = max;
    try std.testing.expectEqual(@as(usize, 7), try limits.maxStringBytes());

    limits = .{
        .max_invalid_reason_bytes = max,
        .max_payer_bytes = 0,
        .max_extensions = 0,
        .max_extensions_string_bytes = 0,
        .max_extra_string_bytes = 0,
    };
    try std.testing.expectEqual(max, try limits.maxStringBytes());

    limits.max_extra_string_bytes = 1;
    try std.testing.expectError(error.Overflow, limits.maxStringBytes());

    const cases = [_]Limits{
        .{ .max_invalid_reason_bytes = max },
        .{ .max_payer_bytes = max },
        .{ .max_extensions_string_bytes = max },
        .{ .max_extra_string_bytes = max },
    };
    for (cases) |case| {
        try std.testing.expectError(error.Overflow, case.maxStringBytes());
    }
}

test "Limits.check accepts boundaries and identifies exceeded fields" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"a":{"b":"c"}}
    , .{});
    defer parsed.deinit();

    const limits: Limits = .{
        .max_invalid_reason_bytes = 3,
        .max_payer_bytes = 2,
        .max_extensions = 1,
        .max_extensions_string_bytes = 3,
        .max_extra_string_bytes = 3,
    };
    const response: VerifyResponse = .{
        .is_valid = false,
        .invalid_reason = "err",
        .payer = "pp",
        .extensions = parsed.value.object,
        .extra = parsed.value.object,
    };
    try limits.check(response);

    const cases = .{
        .{ "invalid_reason", 3, error.InvalidReasonTooLong },
        .{ "payer", 2, error.PayerTooLong },
    };
    inline for (cases) |case| {
        var oversized = response;
        @field(oversized, case[0]) =
            &@as([case[1] + 1]u8, @splat('x'));
        try std.testing.expectError(case[2], limits.check(oversized));
    }

    const object_cases = .{
        .{ "max_extensions", 0, error.TooManyExtensions },
        .{ "max_extensions_string_bytes", 2, error.ExtensionsTooLong },
        .{ "max_extra_string_bytes", 2, error.ExtraTooLong },
    };
    inline for (object_cases) |case| {
        var reduced = limits;
        @field(reduced, case[0]) = case[1];
        try std.testing.expectError(case[2], reduced.check(response));
    }

    const zero_limits: Limits = .{
        .max_invalid_reason_bytes = 0,
        .max_payer_bytes = 0,
        .max_extensions = 0,
        .max_extensions_string_bytes = 0,
        .max_extra_string_bytes = 0,
    };
    var empty: VerifyResponse = .{ .is_valid = true };

    // Absent and empty optional fields fit zero budgets.
    try zero_limits.check(empty);
    empty.invalid_reason = "";
    empty.payer = "";
    empty.extensions = .{};
    empty.extra = .{};
    try zero_limits.check(empty);
}
