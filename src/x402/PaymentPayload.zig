//! An object describing the client payment message.
//!
//! Specification: x402 v2, 5.2.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions borrow caller-owned memory,
//! which must remain valid while the payment message is in use.

const std = @import("std");
const ResourceInfo = @import("ResourceInfo.zig");
const PaymentRequirements = @import("PaymentRequirements.zig");
const json_limits = @import("json_limits.zig");

const PaymentPayload = @This();

// Fields.

/// Protocol version identifier.
x402_version: u8,

/// ResourceInfo object describing the resource being accessed.
resource: ?ResourceInfo = null,

/// Payment requirement object indicating the payment method chosen.
accepted: PaymentRequirements,

/// Scheme-specific payment data.
payload: std.json.ObjectMap,

/// Protocol extensions data.
extensions: ?std.json.ObjectMap = null,

pub const LimitError = ResourceInfo.LimitError || PaymentRequirements.LimitError || error{
    PayloadTooLong,
    TooManyExtensions,
    ExtensionsTooLong,
};

///  Library default limits for collection counts and decoded UTF-8 string bytes.
pub const Limits = struct {
    resource: ResourceInfo.Limits = .{},
    accepted: PaymentRequirements.Limits = .{},

    /// Maximum total UTF-8 bytes of decoded keys and string values in payload.
    max_payload_string_bytes: usize = 16 * 1024,

    max_extensions: usize = 16,

    /// Maximum total UTF-8 bytes of decoded keys and values in extensions.
    max_extensions_string_bytes: usize = 16 * 1024,

    /// Maximum byte length for all decoded string values.
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = try limits.resource.maxStringBytes();
        total = try std.math.add(usize, total, try limits.accepted.maxStringBytes());
        total = try std.math.add(usize, total, limits.max_payload_string_bytes);
        if (limits.max_extensions > 0) {
            total = try std.math.add(usize, total, limits.max_extensions_string_bytes);
        }
        return total;
    }

    /// Checks decoded strings against the limits.
    pub fn check(limits: Limits, payment: PaymentPayload) LimitError!void {
        if (payment.resource) |resource| {
            try limits.resource.check(resource);
        }

        try limits.accepted.check(payment.accepted);

        json_limits.checkStringBytes(
            .{ .object = payment.payload },
            limits.max_payload_string_bytes,
        ) catch return LimitError.PayloadTooLong;

        if (payment.extensions) |extensions| {
            if (extensions.count() > limits.max_extensions)
                return error.TooManyExtensions;

            json_limits.checkStringBytes(
                .{ .object = extensions },
                limits.max_extensions_string_bytes,
            ) catch return LimitError.ExtensionsTooLong;
        }
    }
};

test "Limits.maxStringBytes handles custom limits and overflow" {
    var limits: Limits = .{
        .resource = .{ .max_url_bytes = 17 },
        .accepted = .{ .max_scheme_bytes = 19 },
        .max_payload_string_bytes = 7,
        .max_extensions = 2,
        .max_extensions_string_bytes = 11,
    };
    const resource = try limits.resource.maxStringBytes();
    const accepted = try limits.accepted.maxStringBytes();

    // The extension budget is a total, not a per-extension limit.
    try std.testing.expectEqual(
        resource + accepted + 7 + 11,
        try limits.maxStringBytes(),
    );

    const max = std.math.maxInt(usize);

    // Disabled extensions do not contribute, even with a huge budget.
    limits.max_extensions = 0;
    limits.max_extensions_string_bytes = max;
    try std.testing.expectEqual(
        resource + accepted + 7,
        try limits.maxStringBytes(),
    );

    // The largest representable total is allowed.
    limits.max_payload_string_bytes = max - resource - accepted;
    try std.testing.expectEqual(max, try limits.maxStringBytes());

    limits.max_payload_string_bytes += 1;
    try std.testing.expectError(error.Overflow, limits.maxStringBytes());

    const default_resource = try (ResourceInfo.Limits{}).maxStringBytes();
    const default_accepted = try (PaymentRequirements.Limits{}).maxStringBytes();

    const cases = [_]Limits{
        // Overflow while calculating accepted.
        .{ .accepted = .{ .max_extra_string_bytes = max } },

        // Overflow while combining resource and accepted.
        .{
            .resource = .{
                .max_url_bytes = max -
                    (default_resource - (ResourceInfo.Limits{}).max_url_bytes),
            },
            .max_payload_string_bytes = 0,
            .max_extensions = 0,
        },

        // Overflow while adding the payload budget.
        .{ .max_payload_string_bytes = max },

        // Overflow while adding the extension budget.
        .{
            .max_payload_string_bytes = max - default_resource - default_accepted,
            .max_extensions = 1,
            .max_extensions_string_bytes = 1,
        },
    };
    for (cases) |case| {
        try std.testing.expectError(error.Overflow, case.maxStringBytes());
    }
}

test "Limits.check accepts boundaries and identifies exceeded fields" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"a":null}
    , .{});
    defer parsed.deinit();

    const payment: PaymentPayload = .{
        .x402_version = 2,
        .resource = .{ .url = "url" },
        .accepted = .{
            .scheme = "exact",
            .network = "eip155:1",
            .amount = "1",
            .asset = "asset",
            .pay_to = "recipient",
            .max_timeout_seconds = 60,
        },
        .payload = parsed.value.object,
        .extensions = parsed.value.object,
    };

    const limits: Limits = .{
        .resource = .{ .max_url_bytes = 3 },
        .accepted = .{ .max_scheme_bytes = 5 },
        .max_payload_string_bytes = 1,
        .max_extensions = 1,
        .max_extensions_string_bytes = 1,
    };
    try limits.check(payment);

    const cases = .{
        .{
            "resource",
            ResourceInfo.Limits{ .max_url_bytes = 2 },
            error.UrlTooLong,
        },
        .{
            "accepted",
            PaymentRequirements.Limits{ .max_scheme_bytes = 4 },
            error.SchemeTooLong,
        },
        .{ "max_payload_string_bytes", 0, error.PayloadTooLong },
        .{ "max_extensions_string_bytes", 0, error.ExtensionsTooLong },
        .{ "max_extensions", 0, error.TooManyExtensions },
    };

    inline for (cases) |case| {
        var reduced = limits;
        @field(reduced, case[0]) = case[1];
        try std.testing.expectError(case[2], reduced.check(payment));
    }

    // Empty JSON objects fit zero budgets; optional fields may be absent.
    var empty = payment;
    empty.resource = null;
    empty.payload = .{};
    empty.extensions = null;

    const zero_limits: Limits = .{
        .max_payload_string_bytes = 0,
        .max_extensions = 0,
        .max_extensions_string_bytes = 0,
    };
    try zero_limits.check(empty);

    empty.extensions = .{};
    try zero_limits.check(empty);
}
