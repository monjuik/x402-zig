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
const json_parse = @import("json_parse.zig");

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

pub fn jsonStringify(self: PaymentPayload, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("x402Version");
    try jw.write(self.x402_version);

    if (self.resource) |value| {
        try jw.objectField("resource");
        try jw.write(value);
    }

    try jw.objectField("accepted");
    try jw.write(self.accepted);

    try jw.objectField("payload");
    try jw.write(std.json.Value{ .object = self.payload });

    if (self.extensions) |value| {
        try jw.objectField("extensions");
        try jw.write(std.json.Value{ .object = value });
    }

    try jw.endObject();
}

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

pub const ParseOptions = struct {
    limits: Limits = .{},
};

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    options: ParseOptions,
) !PaymentPayload {
    const payload = try json_parse.parse(PaymentPayload, allocator, reader);
    try options.limits.check(payload);
    return payload;
}

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !PaymentPayload {
    const json = try std.json.innerParse(Json, allocator, source, options);
    return json.toPaymentPayload();
}

const Json = struct {
    x402Version: u8,
    resource: ?ResourceInfo = null,
    accepted: PaymentRequirements,
    payload: std.json.ArrayHashMap(std.json.Value),
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,

    fn toPaymentPayload(self: Json) PaymentPayload {
        return .{
            .x402_version = self.x402Version,
            .resource = self.resource,
            .accepted = self.accepted,
            .payload = self.payload.map,
            .extensions = if (self.extensions) |value| value.map else null,
        };
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

test "jsonStringify writes payment payload and optional fields" {
    var payment: PaymentPayload = .{
        .x402_version = 2,
        .accepted = .{
            .scheme = "exact",
            .network = "eip155:1",
            .amount = "100",
            .asset = "asset",
            .pay_to = "recipient",
            .max_timeout_seconds = 60,
        },
        .payload = .{},
    };

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.json.Stringify.value(payment, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"x402Version":2,"accepted":{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60},"payload":{}}
    , writer.buffered());

    payment.resource = .{ .url = "url" };
    payment.extensions = .{};
    writer = .fixed(&buffer);

    try std.json.Stringify.value(payment, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"x402Version":2,"resource":{"url":"url"},"accepted":{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60},"payload":{},"extensions":{}}
    , writer.buffered());
}

test "parse maps PaymentPayload and nested types" {
    const input =
        \\{"x402Version":2,"resource":{"url":"url","mimeType":"application/json"},"accepted":{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60},"payload":{"signature":"sig"},"extensions":{}}
    ;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const payment = try PaymentPayload.parse(fba.allocator(), &reader, .{});

    try std.testing.expectEqual(@as(u8, 2), payment.x402_version);
    try std.testing.expectEqualStrings("url", payment.resource.?.url);
    try std.testing.expectEqualStrings(
        "application/json",
        payment.resource.?.mime_type.?,
    );
    try std.testing.expectEqualStrings("recipient", payment.accepted.pay_to);

    try std.testing.expectEqual(@as(usize, 1), payment.payload.count());
    try std.testing.expectEqualStrings(
        "sig",
        payment.payload.get("signature").?.string,
    );
    try std.testing.expectEqual(@as(usize, 0), payment.extensions.?.count());
}

test "parse enforces custom payload limit" {
    const input =
        \\{"x402Version":2,"accepted":{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60},"payload":{"a":"b"}}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.PayloadTooLong,
        PaymentPayload.parse(fba.allocator(), &reader, .{
            .limits = .{ .max_payload_string_bytes = 1 },
        }),
    );
}
