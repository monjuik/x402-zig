//! An object describing the response structure.
//!
//! Specification: x402 v2, 5.1.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions borrow caller-owned memory,
//! which must remain valid while the response is in use.

const std = @import("std");
const ResourceInfo = @import("ResourceInfo.zig");
const PaymentRequirements = @import("PaymentRequirements.zig");
const Amount = @import("Amount.zig");
const Network = @import("Network.zig");
const json_parse = @import("json_parse.zig");

const PaymentRequired = @This();

// Fields.

/// Protocol version identifier (must be 2).
x402_version: u8,

/// Human-readable error message explaining why payment is required.
@"error": ?[]const u8 = null, // tricky name as it's a reserved keyword

/// ResourceInfo object describing the protected resource.
resource: ResourceInfo,

/// Array of payment requirement objects defining acceptable payment methods.
accepts: []const PaymentRequirements,

/// Protocol extensions data.
extensions: ?std.json.ObjectMap = null,

pub fn jsonStringify(self: PaymentRequired, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("x402Version");
    try jw.write(self.x402_version);

    if (self.@"error") |value| {
        try jw.objectField("error");
        try jw.write(value);
    }

    try jw.objectField("resource");
    try jw.write(self.resource);

    try jw.objectField("accepts");
    try jw.write(self.accepts);

    if (self.extensions) |value| {
        try jw.objectField("extensions");
        try jw.write(std.json.Value{ .object = value });
    }

    try jw.endObject();
}

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !PaymentRequired {
    const response = try json_parse.parse(PaymentRequired, allocator, reader);
    try response.validate();
    return response;
}

pub fn validate(self: PaymentRequired) (ResourceInfo.ValidationError || error{UnsupportedVersion})!void {
    if (self.x402_version != 2)
        return error.UnsupportedVersion;

    try self.resource.validate();
}

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !PaymentRequired {
    const json = try std.json.innerParse(Json, allocator, source, options);
    return json.toPaymentRequired();
}

const Json = struct {
    x402Version: u8,
    @"error": ?[]const u8 = null,
    resource: ResourceInfo,
    accepts: []const PaymentRequirements,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,

    fn toPaymentRequired(self: Json) PaymentRequired {
        return .{
            .x402_version = self.x402Version,
            .@"error" = self.@"error",
            .resource = self.resource,
            .accepts = self.accepts,
            .extensions = if (self.extensions) |value| value.map else null,
        };
    }
};

test "jsonStringify writes nested payment requirements and optional fields" {
    var response: PaymentRequired = .{
        .x402_version = 2,
        .resource = .{ .url = "url" },
        .accepts = &.{.{
            .scheme = "exact",
            .network = try Network.parse("eip155:1"),
            .amount = try Amount.parse("100"),
            .asset = "asset",
            .pay_to = "recipient",
            .max_timeout_seconds = 60,
        }},
    };

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.json.Stringify.value(response, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"x402Version":2,"resource":{"url":"url"},"accepts":[{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}]}
    , writer.buffered());

    response.@"error" = "Payment required";
    response.extensions = .{};
    writer = .fixed(&buffer);

    try std.json.Stringify.value(response, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"x402Version":2,"error":"Payment required","resource":{"url":"url"},"accepts":[{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}],"extensions":{}}
    , writer.buffered());
}

test "parse maps PaymentRequired and nested types" {
    const input =
        \\{"x402Version":2,"error":"Payment required","resource":{"url":"url","mimeType":"application/json"},"accepts":[{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}],"extensions":{"example":true}}
    ;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const response = try PaymentRequired.parse(fba.allocator(), &reader);

    try std.testing.expectEqual(@as(u8, 2), response.x402_version);
    try std.testing.expectEqualStrings("Payment required", response.@"error".?);
    try std.testing.expectEqualStrings("url", response.resource.url);
    try std.testing.expectEqualStrings(
        "application/json",
        response.resource.mime_type.?,
    );

    try std.testing.expectEqual(@as(usize, 1), response.accepts.len);
    try std.testing.expectEqualStrings("recipient", response.accepts[0].pay_to);

    try std.testing.expectEqualStrings("100", response.accepts[0].amount.bytes);

    const extensions = response.extensions.?;
    try std.testing.expectEqual(@as(usize, 1), extensions.count());
    try std.testing.expect(extensions.get("example").?.bool);
}

test "parse rejects a network wildcard in accepts" {
    const input =
        \\{"x402Version":2,"resource":{"url":"url"},"accepts":[{"scheme":"exact","network":"eip155:*","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}]}
    ;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.UnexpectedToken,
        PaymentRequired.parse(fba.allocator(), &reader),
    );
}

test "parse rejects invalid amount in accepts" {
    const input =
        \\{"x402Version":2,"resource":{"url":"url"},"accepts":[{"scheme":"exact","network":"eip155:1","amount":"01","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}]}
    ;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.InvalidNumber,
        PaymentRequired.parse(fba.allocator(), &reader),
    );
}

test "parse rejects unsupported x402 versions" {
    for ([_]u8{ 0, 1, 3, 255 }) |version| {
        var input_buffer: [256]u8 = undefined;
        const input = try std.fmt.bufPrint(
            &input_buffer,
            "{{\"x402Version\":{d},\"resource\":{{\"url\":\"url\"}},\"accepts\":[]}}",
            .{version},
        );

        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(input);

        try std.testing.expectError(
            error.UnsupportedVersion,
            PaymentRequired.parse(fba.allocator(), &reader),
        );
    }
}
