//! An object describing the payment verification result.
//!
//! Specification: x402 v2, 5.4.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions and extra borrow caller-owned memory,
//! which must remain valid while the result is in use.

const std = @import("std");
const json_parse = @import("json_parse.zig");

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

pub fn jsonStringify(self: VerifyResponse, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("isValid");
    try jw.write(self.is_valid);

    if (self.invalid_reason) |value| {
        try jw.objectField("invalidReason");
        try jw.write(value);
    }

    if (self.payer) |value| {
        try jw.objectField("payer");
        try jw.write(value);
    }

    if (self.extensions) |value| {
        try jw.objectField("extensions");
        try jw.write(std.json.Value{ .object = value });
    }

    if (self.extra) |value| {
        try jw.objectField("extra");
        try jw.write(std.json.Value{ .object = value });
    }

    try jw.endObject();
}

pub const ParseError = json_parse.ParseError;

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ParseError!VerifyResponse {
    return json_parse.parse(VerifyResponse, allocator, reader);
}

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !VerifyResponse {
    const json = try std.json.innerParse(Json, allocator, source, options);
    return json.toVerifyResponse();
}

const Json = struct {
    isValid: bool,
    invalidReason: ?[]const u8 = null,
    payer: ?[]const u8 = null,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
    extra: ?std.json.ArrayHashMap(std.json.Value) = null,

    fn toVerifyResponse(self: Json) VerifyResponse {
        return .{
            .is_valid = self.isValid,
            .invalid_reason = self.invalidReason,
            .payer = self.payer,
            .extensions = if (self.extensions) |value| value.map else null,
            .extra = if (self.extra) |value| value.map else null,
        };
    }
};

test "jsonStringify writes verification result and optional fields" {
    var response: VerifyResponse = .{ .is_valid = true };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.json.Stringify.value(response, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"isValid":true}
    , writer.buffered());

    response.is_valid = false;
    response.invalid_reason = "invalid_signature";
    response.payer = "payer";
    response.extensions = .{};
    response.extra = .{};
    writer = .fixed(&buffer);

    try std.json.Stringify.value(response, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"isValid":false,"invalidReason":"invalid_signature","payer":"payer","extensions":{},"extra":{}}
    , writer.buffered());
}

test "parse maps VerifyResponse fields and maps" {
    const input =
        \\{"isValid":false,"invalidReason":"invalid_signature","payer":"payer","extensions":{"example":true},"extra":{"detail":"signature"}}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const response = try VerifyResponse.parse(fba.allocator(), &reader);

    try std.testing.expect(!response.is_valid);
    try std.testing.expectEqualStrings(
        "invalid_signature",
        response.invalid_reason.?,
    );
    try std.testing.expectEqualStrings("payer", response.payer.?);
    try std.testing.expect(response.extensions.?.get("example").?.bool);
    try std.testing.expectEqualStrings(
        "signature",
        response.extra.?.get("detail").?.string,
    );
}
