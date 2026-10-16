//! An object describing the payment requirements.
//!
//! Specification: x402 v2, 5.1.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extra borrow caller-owned memory,
//! which must remain valid while the payment requirements are in use.

const std = @import("std");
const json_parse = @import("json_parse.zig");
const Amount = @import("Amount.zig");
const Network = @import("Network.zig");

const PaymentRequirements = @This();

// Fields.

/// Payment scheme identifier (e.g., “exact”).
scheme: []const u8,

/// Blockchain network identifier in CAIP-2 format (e.g., “eip155:84532”).
network: Network,

/// Required payment amount in atomic token units.
amount: Amount,

/// Token contract address or ISO 4217 currency code for fiat.
asset: []const u8, // ISO 4217 format: three digits or three letters

/// Recipient wallet address or role constant (e.g., “merchant”).
pay_to: []const u8,

/// Maximum time allowed for payment completion.
max_timeout_seconds: u32,

/// Additional information.
/// Reserved protocol keys: assetTransferMethod, paymentFlow; other keys are scheme-specific.
extra: ?std.json.ObjectMap = null,

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

pub const ParseError = json_parse.ParseError;

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ParseError!PaymentRequirements {
    return json_parse.parse(PaymentRequirements, allocator, reader);
}

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !PaymentRequirements {
    const json = try std.json.innerParse(Json, allocator, source, options);
    return json.toPaymentRequirements() catch |err| switch (err) {
        error.InvalidAmount => error.InvalidNumber,
        error.InvalidNetwork => error.UnexpectedToken,
    };
}

const Json = struct {
    scheme: []const u8,
    network: []const u8,
    amount: []const u8,
    asset: []const u8,
    payTo: []const u8,
    maxTimeoutSeconds: u32,
    extra: ?std.json.ArrayHashMap(std.json.Value) = null,

    fn toPaymentRequirements(self: Json) error{ InvalidAmount, InvalidNetwork }!PaymentRequirements {
        return .{
            .scheme = self.scheme,
            .network = try Network.parse(self.network),
            .amount = try Amount.parse(self.amount),
            .asset = self.asset,
            .pay_to = self.payTo,
            .max_timeout_seconds = self.maxTimeoutSeconds,
            .extra = if (self.extra) |value| value.map else null,
        };
    }
};

test "jsonStringify writes protocol fields and optional extra" {
    var requirements: PaymentRequirements = .{
        .scheme = "exact",
        .network = try Network.parse("eip155:1"),
        .amount = try Amount.parse("100"),
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

test "parse maps protocol fields and extra to PaymentRequirements" {
    const input =
        \\{"scheme":"exact","network":"eip155:1","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60,"extra":{"assetTransferMethod":"permit2"}}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const requirements = try PaymentRequirements.parse(
        fba.allocator(),
        &reader,
    );

    try std.testing.expectEqualStrings("exact", requirements.scheme);
    try std.testing.expectEqualStrings("eip155:1", requirements.network.bytes);
    try std.testing.expectEqualStrings("100", requirements.amount.bytes);
    try std.testing.expectEqualStrings("asset", requirements.asset);
    try std.testing.expectEqualStrings("recipient", requirements.pay_to);
    try std.testing.expectEqual(@as(u32, 60), requirements.max_timeout_seconds);

    const extra = requirements.extra.?;
    try std.testing.expectEqual(@as(usize, 1), extra.count());
    try std.testing.expectEqualStrings(
        "permit2",
        extra.get("assetTransferMethod").?.string,
    );
}

test "parse rejects invalid networks" {
    const cases = [_][]const u8{
        \\{"scheme":"exact","network":"eip155:*","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}
        ,
        \\{"scheme":"exact","network":"eip155","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}
        ,
        \\{"scheme":"exact","network":"","amount":"100","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}
        ,
    };

    for (cases) |input| {
        var storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(input);

        try std.testing.expectError(
            error.UnexpectedToken,
            PaymentRequirements.parse(fba.allocator(), &reader),
        );
    }
}

test "parse rejects amount with a leading zero" {
    const input =
        \\{"scheme":"exact","network":"eip155:1","amount":"01","asset":"asset","payTo":"recipient","maxTimeoutSeconds":60}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.InvalidNumber,
        PaymentRequirements.parse(fba.allocator(), &reader),
    );
}
