//! An object with transaction details after payment settlement
//!
//! Specification: x402 v2, 5.3.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions borrow caller-owned memory,
//! which must remain valid while the settlement response is in use.

const std = @import("std");
const json_parse = @import("json_parse.zig");
const Amount = @import("Amount.zig");
const Network = @import("Network.zig");

const SettleResponse = @This();

// Fields.

/// Indicates whether the payment settlement was successful.
success: bool,

/// Error reason if settlement failed (omitted if successful).
error_reason: ?[]const u8 = null,

/// Address of the payer’s wallet.
payer: ?[]const u8 = null,

/// Blockchain transaction hash (empty string if no transaction was broadcast;
/// MUST be non-empty when errorReason is settlement_pending).
transaction: []const u8,

/// Blockchain network identifier in CAIP-2 format.
network: Network,

/// The actual amount settled in atomic units (omitted if not applicable).
amount: ?Amount = null,

/// Protocol extensions data.
extensions: ?std.json.ObjectMap = null,

pub fn jsonStringify(self: SettleResponse, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("success");
    try jw.write(self.success);

    if (self.error_reason) |value| {
        try jw.objectField("errorReason");
        try jw.write(value);
    }

    if (self.payer) |value| {
        try jw.objectField("payer");
        try jw.write(value);
    }

    try jw.objectField("transaction");
    try jw.write(self.transaction);

    try jw.objectField("network");
    try jw.write(self.network);

    if (self.amount) |value| {
        try jw.objectField("amount");
        try jw.write(value);
    }

    if (self.extensions) |value| {
        try jw.objectField("extensions");
        try jw.write(std.json.Value{ .object = value });
    }

    try jw.endObject();
}

pub const ValidationError = error{MissingTransaction};
pub const ParseError = ValidationError || json_parse.ParseError;

pub fn validate(self: SettleResponse) ValidationError!void {
    if (self.error_reason) |reason| {
        // according to 5.3.2 Field Descriptions
        // `transaction` MUST be non-empty when `errorReason` is `settlement_pending`
        if (std.mem.eql(u8, reason, "settlement_pending") and self.transaction.len == 0)
            return error.MissingTransaction;
    }
}

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ParseError!SettleResponse {
    const response = try json_parse.parse(SettleResponse, allocator, reader);
    try response.validate();

    return response;
}

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !SettleResponse {
    const json = try std.json.innerParse(Json, allocator, source, options);
    return json.toSettleResponse() catch |err| switch (err) {
        error.InvalidAmount => error.InvalidNumber,
        error.InvalidNetwork => error.UnexpectedToken,
    };
}

const Json = struct {
    success: bool,
    errorReason: ?[]const u8 = null,
    payer: ?[]const u8 = null,
    transaction: []const u8,
    network: []const u8,
    amount: ?[]const u8 = null,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,

    fn toSettleResponse(self: Json) error{ InvalidAmount, InvalidNetwork }!SettleResponse {
        return .{
            .success = self.success,
            .error_reason = self.errorReason,
            .payer = self.payer,
            .transaction = self.transaction,
            .network = try Network.parse(self.network),
            .amount = if (self.amount) |bytes| try Amount.parse(bytes) else null,
            .extensions = if (self.extensions) |value| value.map else null,
        };
    }
};

test "jsonStringify writes settlement result and optional fields" {
    var response: SettleResponse = .{
        .success = false,
        .transaction = "",
        .network = try Network.parse("eip155:1"),
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.json.Stringify.value(response, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"success":false,"transaction":"","network":"eip155:1"}
    , writer.buffered());

    response.error_reason = "settlement_pending";
    response.payer = "payer";
    response.transaction = "tx";
    response.amount = try Amount.parse("100");
    response.extensions = .{};
    writer = .fixed(&buffer);

    try std.json.Stringify.value(response, .{}, &writer);
    try std.testing.expectEqualStrings(
        \\{"success":false,"errorReason":"settlement_pending","payer":"payer","transaction":"tx","network":"eip155:1","amount":"100","extensions":{}}
    , writer.buffered());
}

test "parse maps SettleResponse fields and extensions" {
    const input =
        \\{"success":false,"errorReason":"settlement_pending","payer":"payer","transaction":"tx","network":"eip155:1","amount":"100","extensions":{"example":true}}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const response = try SettleResponse.parse(fba.allocator(), &reader);

    try std.testing.expect(!response.success);
    try std.testing.expectEqualStrings(
        "settlement_pending",
        response.error_reason.?,
    );
    try std.testing.expectEqualStrings("payer", response.payer.?);
    try std.testing.expectEqualStrings("tx", response.transaction);
    try std.testing.expectEqualStrings("eip155:1", response.network.bytes);
    try std.testing.expectEqualStrings("100", response.amount.?.bytes);
    try std.testing.expect(response.extensions.?.get("example").?.bool);
}

test "parse rejects invalid networks in successful and failed settlements" {
    const cases = [_][]const u8{
        \\{"success":true,"transaction":"tx","network":"eip155:*"}
        ,
        \\{"success":false,"transaction":"","network":"eip155:*"}
        ,
        \\{"success":false,"transaction":"","network":""}
        ,
        \\{"success":true,"transaction":"tx","network":"eip155"}
        ,
        \\{"success":false,"errorReason":"settlement_pending","transaction":"tx","network":"eip155:*"}
        ,
    };

    for (cases) |input| {
        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(input);

        try std.testing.expectError(
            error.UnexpectedToken,
            SettleResponse.parse(fba.allocator(), &reader),
        );
    }
}

test "parse accepts absent and null amount" {
    const inputs = [_][]const u8{
        \\{"success":true,"transaction":"tx","network":"eip155:1"}
        ,
        \\{"success":true,"transaction":"tx","network":"eip155:1","amount":null}
        ,
    };

    for (inputs) |input| {
        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(input);

        const response = try SettleResponse.parse(
            fba.allocator(),
            &reader,
        );
        try std.testing.expect(response.amount == null);
    }
}

test "parse rejects invalid amount" {
    const cases = .{
        .{
            \\{"success":true,"transaction":"tx","network":"eip155:1","amount":"01"}
            ,
            error.InvalidNumber,
        },
        .{
            \\{"success":true,"transaction":"tx","network":"eip155:1","amount":""}
            ,
            error.InvalidNumber,
        },
        .{
            \\{"success":true,"transaction":"tx","network":"eip155:1","amount":100}
            ,
            error.UnexpectedToken,
        },
    };

    inline for (cases) |case| {
        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(case[0]);

        try std.testing.expectError(
            case[1],
            SettleResponse.parse(fba.allocator(), &reader),
        );
    }
}

test "parse rejects pending settlement without transaction" {
    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(
        \\{"success":false,"errorReason":"settlement_pending","transaction":"","network":"eip155:1"}
    );

    try std.testing.expectError(
        error.MissingTransaction,
        SettleResponse.parse(fba.allocator(), &reader),
    );
}

test "parse accepts pending transaction and other failures without transaction" {
    const inputs = [_][]const u8{
        \\{"success":false,"errorReason":"settlement_pending","transaction":"tx","network":"eip155:1"}
        ,
        \\{"success":false,"errorReason":"insufficient_funds","transaction":"","network":"eip155:1"}
        ,
    };

    for (inputs) |input| {
        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(input);

        _ = try SettleResponse.parse(fba.allocator(), &reader);
    }
}
