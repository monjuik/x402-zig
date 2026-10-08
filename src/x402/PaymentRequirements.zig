//! An object describing the payment requirements.
//!
//! Specification: x402 v2, 5.1.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extra borrow caller-owned memory,
//! which must remain valid while the payment requirements are in use.

const std = @import("std");
const json_limits = @import("json_limits.zig");

const PaymentRequirements = @This();

// Fields.

/// Payment scheme identifier (e.g., “exact”).
scheme: []const u8,

/// Blockchain network identifier in CAIP-2 format (e.g., “eip155:84532”).
network: []const u8, // https://github.com/ChainAgnostic/CAIPs/blob/main/CAIPs/caip-2.md

/// Required payment amount in atomic token units.
amount: []const u8,

/// Token contract address or ISO 4217 currency code for fiat.
asset: []const u8, // ISO 4217 format: three digits or three letters

/// Recipient wallet address or role constant (e.g., “merchant”).
pay_to: []const u8,

/// Maximum time allowed for payment completion.
max_timeout_seconds: u32,

/// Additional information.
/// Reserved protocol keys: assetTransferMethod, paymentFlow; other keys are scheme-specific.
extra: ?std.json.ObjectMap = null,

// Specification limits.
pub const max_network_bytes = 41; // inherited from CAIP-2: 8 + 1 + 32 = 41

pub fn jsonStringify(self: PaymentRequirements, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("scheme");
    try jw.write(self.scheme);

    try jw.objectField("network");
    try jw.write(self.network);

    try jw.objectField("amount");
    try jw.write(self.amount);

    try jw.objectField("asset");
    try jw.write(self.asset);

    try jw.objectField("payTo");
    try jw.write(self.pay_to);

    try jw.objectField("maxTimeoutSeconds");
    try jw.write(self.max_timeout_seconds);

    if (self.extra) |value| {
        try jw.objectField("extra");
        try jw.write(std.json.Value{ .object = value });
    }

    try jw.endObject();
}

pub const LimitError = error{
    SchemeTooLong,
    NetworkTooLong,
    AmountTooLong,
    AssetTooLong,
    PayToTooLong,
    ExtraTooLong,
};

/// Library default limits for decoded strings, measured in UTF-8 bytes.
pub const Limits = struct {
    max_scheme_bytes: usize = 64,
    max_amount_bytes: usize = 128,
    max_asset_bytes: usize = 256,
    max_pay_to_bytes: usize = 256,

    /// Maximum total UTF-8 bytes of decoded keys and values in extra.
    max_extra_string_bytes: usize = 4096,

    /// Maximum byte length for all decoded string values.
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = max_network_bytes;
        total = try std.math.add(usize, total, limits.max_scheme_bytes);
        total = try std.math.add(usize, total, limits.max_amount_bytes);
        total = try std.math.add(usize, total, limits.max_asset_bytes);
        total = try std.math.add(usize, total, limits.max_pay_to_bytes);
        total = try std.math.add(usize, total, limits.max_extra_string_bytes);
        return total;
    }

    /// Checks decoded string sizes against the limits.
    pub fn check(limits: Limits, requirements: PaymentRequirements) LimitError!void {
        if (requirements.scheme.len > limits.max_scheme_bytes)
            return error.SchemeTooLong;

        if (requirements.network.len > max_network_bytes)
            return error.NetworkTooLong;

        if (requirements.amount.len > limits.max_amount_bytes)
            return error.AmountTooLong;

        if (requirements.asset.len > limits.max_asset_bytes)
            return error.AssetTooLong;

        if (requirements.pay_to.len > limits.max_pay_to_bytes)
            return error.PayToTooLong;

        if (requirements.extra) |extra| {
            json_limits.checkStringBytes(
                .{ .object = extra },
                limits.max_extra_string_bytes,
            ) catch return LimitError.ExtraTooLong;
        }
    }
};

test "Limits.maxStringBytes handles custom limits and overflow" {
    var limits: Limits = .{
        .max_scheme_bytes = 1,
        .max_amount_bytes = 2,
        .max_asset_bytes = 3,
        .max_pay_to_bytes = 4,
        .max_extra_string_bytes = 5,
    };
    try std.testing.expectEqual(@as(usize, 56), try limits.maxStringBytes());

    limits = .{
        .max_scheme_bytes = std.math.maxInt(usize) - max_network_bytes,
        .max_amount_bytes = 0,
        .max_asset_bytes = 0,
        .max_pay_to_bytes = 0,
        .max_extra_string_bytes = 0,
    };
    try std.testing.expectEqual(
        std.math.maxInt(usize),
        try limits.maxStringBytes(),
    );

    limits.max_extra_string_bytes = 1;
    try std.testing.expectError(error.Overflow, limits.maxStringBytes());
}

test "Limits.check accepts boundaries and identifies exceeded fields" {
    const limits: Limits = .{
        .max_scheme_bytes = 3,
        .max_amount_bytes = 3,
        .max_asset_bytes = 3,
        .max_pay_to_bytes = 3,
        .max_extra_string_bytes = 0,
    };
    const requirements: PaymentRequirements = .{
        .scheme = "sss",
        .network = &@as([max_network_bytes]u8, @splat('n')),
        .amount = "123",
        .asset = "aaa",
        .pay_to = "ppp",
        .max_timeout_seconds = 60,
    };
    try limits.check(requirements);

    const cases = .{
        .{ "scheme", 3, error.SchemeTooLong },
        .{ "network", max_network_bytes, error.NetworkTooLong },
        .{ "amount", 3, error.AmountTooLong },
        .{ "asset", 3, error.AssetTooLong },
        .{ "pay_to", 3, error.PayToTooLong },
    };
    inline for (cases) |case| {
        var oversized = requirements;
        @field(oversized, case[0]) = &@as([(case[1] + 1)]u8, @splat('x'));
        try std.testing.expectError(case[2], limits.check(oversized));
    }
    // Absent extra was checked above; empty extra also fits a zero budget.
    var with_extra = requirements;
    with_extra.extra = .{};
    try limits.check(with_extra);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"a":null}
    ,
        .{},
    );
    defer parsed.deinit();
    with_extra.extra = parsed.value.object;
    var extra_limits = limits;
    extra_limits.max_extra_string_bytes = 1;
    try extra_limits.check(with_extra);
    try std.testing.expectError(error.ExtraTooLong, limits.check(with_extra));
}

test "jsonStringify writes protocol fields and optional extra" {
    var requirements: PaymentRequirements = .{
        .scheme = "exact",
        .network = "eip155:1",
        .amount = "100",
        .asset = "asset",
        .pay_to = "recipient",
        .max_timeout_seconds = 60,
    };

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.json.Stringify.value(requirements, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}
    , writer.buffered());

    var extra: std.json.ObjectMap = .{};
    defer extra.deinit(std.testing.allocator);
    try extra.put(
        std.testing.allocator,
        "assetTransferMethod",
        .{ .string = "permit2" },
    );

    requirements.extra = extra;
    writer = .fixed(&buffer);

    try std.json.Stringify.value(requirements, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60,"extra":{"assetTransferMethod":"permit2"}}
    , writer.buffered());
}
