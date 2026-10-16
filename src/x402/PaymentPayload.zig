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
const Amount = @import("Amount.zig");
const Network = @import("Network.zig");
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

pub const ValidationError = ResourceInfo.ValidationError || error{UnsupportedVersion};
pub const ParseError = ValidationError || json_parse.ParseError;

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ParseError!PaymentPayload {
    const payload = try json_parse.parse(PaymentPayload, allocator, reader);
    try payload.validate();
    return payload;
}

pub fn validate(self: PaymentPayload) ValidationError!void {
    if (self.x402_version != 2)
        return error.UnsupportedVersion;

    if (self.resource) |resource| try resource.validate();
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

test "jsonStringify writes payment payload and optional fields" {
    var payment: PaymentPayload = .{
        .x402_version = 2,
        .accepted = .{
            .scheme = "exact",
            .network = try Network.parse("eip155:1"),
            .amount = try Amount.parse("100"),
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

    const payment = try PaymentPayload.parse(fba.allocator(), &reader);

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
    try std.testing.expectEqualStrings("100", payment.accepted.amount.bytes);
}

test "parse rejects a network wildcard in accepted" {
    const input =
        \\{"x402Version":2,"accepted":{"scheme":"exact","network":"eip155:*","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60},"payload":{}}
    ;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.UnexpectedToken,
        PaymentPayload.parse(fba.allocator(), &reader),
    );
}

test "parse rejects invalid amount in accepted" {
    const input =
        \\{"x402Version":2,"accepted":{"scheme":"exact","network":"eip155:1","amount":"01","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60},"payload":{}}
    ;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.InvalidNumber,
        PaymentPayload.parse(fba.allocator(), &reader),
    );
}

test "parse rejects unsupported x402 versions" {
    for ([_]u8{ 0, 1, 3, 255 }) |version| {
        var input_buffer: [512]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &input_buffer,
            "{{\"x402Version\":{d},\"accepted\":{{\"scheme\":\"exact\",\"network\":\"eip155:1\",\"amount\":\"100\",\"asset\":\"asset\",\"payTo\":\"recipient\",\"maxTimeoutSeconds\":60}},\"payload\":{{}}}}",
            .{version},
        );

        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(input);

        try std.testing.expectError(
            error.UnsupportedVersion,
            PaymentPayload.parse(fba.allocator(), &reader),
        );
    }
}
