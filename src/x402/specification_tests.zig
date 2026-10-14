//! Tests for examples in the x402 v2 specification.
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md

const std = @import("std");
const PaymentRequired = @import("PaymentRequired.zig");
const PaymentPayload = @import("PaymentPayload.zig");
const PaymentRequirements = @import("PaymentRequirements.zig");
const ResourceInfo = @import("ResourceInfo.zig");
const SettleResponse = @import("SettleResponse.zig");
const VerifyResponse = @import("VerifyResponse.zig");

const expectEqual = std.testing.expectEqual;
const expectString = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn checkExample(
    comptime T: type,
    input: []const u8,
    comptime check: fn (T) anyerror!void,
) !void {
    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const value = try T.parse(fba.allocator(), &reader, .{});
    try check(value);
}

fn checkResource(resource: ResourceInfo) !void {
    try expectString("https://api.example.com/premium-data", resource.url);
    try expectString("Access to premium market data", resource.description.?);
    try expectString("application/json", resource.mime_type.?);
}

fn checkRequirements(requirements: PaymentRequirements) !void {
    try PaymentRequirements.Limits.check(.{}, requirements);
    try expectString("exact", requirements.scheme);
    try expectString("eip155:84532", requirements.network.bytes);
    try expectString("10000", requirements.amount.bytes);
    try expectString("0x036CbD53842c5426634e7929541eC2318f3dCF7e", requirements.asset);
    try expectString("0x209693Bc6afc0C5328bA36FaF03C514EF312287C", requirements.pay_to);
    try expectEqual(@as(u32, 60), requirements.max_timeout_seconds);

    const extra = requirements.extra.?;
    try expectEqual(@as(usize, 2), extra.count());
    try expectString("USDC", extra.get("name").?.string);
    try expectString("2", extra.get("version").?.string);
}

fn checkAuthorization(payload: std.json.ObjectMap, from: []const u8, to: []const u8, nonce: []const u8) !void {
    try expectEqual(@as(usize, 2), payload.count());
    const authorization = payload.get("authorization").?.object;
    try expectEqual(@as(usize, 6), authorization.count());
    try expectString(from, authorization.get("from").?.string);
    try expectString(to, authorization.get("to").?.string);
    try expectString("10000", authorization.get("value").?.string);
    try expectString("1740672089", authorization.get("validAfter").?.string);
    try expectString("1740672154", authorization.get("validBefore").?.string);
    try expectString(nonce, authorization.get("nonce").?.string);
}

fn checkSettlement(response: SettleResponse, success: bool) !void {
    try expectEqual(success, response.success);
    try expectString("0x857b06519E91e3A54538791bDbb0E22373e36b66", response.payer.?);
    try expectString("eip155:84532", response.network.bytes);
    try expectString(if (success) "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" else "", response.transaction);
    if (success)
        try expect(response.error_reason == null)
    else
        try expectString("insufficient_funds", response.error_reason.?);
    try expect(response.amount == null);
    try expect(response.extensions == null);
}

test "spec v2 section 5.1.1: PaymentRequired" {
    const input =
        \\{
        \\  "x402Version": 2,
        \\  "error": "PAYMENT-SIGNATURE header is required",
        \\  "resource": {
        \\    "url": "https://api.example.com/premium-data",
        \\    "description": "Access to premium market data",
        \\    "mimeType": "application/json",
        \\    "serviceName": "Example Market Data",
        \\    "tags": ["market-data", "finance"],
        \\    "iconUrl": "https://api.example.com/icon.png"
        \\  },
        \\  "accepts": [
        \\    {
        \\      "scheme": "exact",
        \\      "network": "eip155:84532",
        \\      "amount": "10000",
        \\      "asset": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        \\      "payTo": "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
        \\      "maxTimeoutSeconds": 60,
        \\      "extra": {
        \\        "name": "USDC",
        \\        "version": "2"
        \\      }
        \\    }
        \\  ],
        \\  "extensions": {}
        \\}
    ;

    try checkExample(PaymentRequired, input, struct {
        fn check(response: PaymentRequired) !void {
            try expectEqual(@as(u8, 2), response.x402_version);
            try expectString("PAYMENT-SIGNATURE header is required", response.@"error".?);
            try checkResource(response.resource);
            try expectString("Example Market Data", response.resource.service_name.?);
            try expectString("https://api.example.com/icon.png", response.resource.icon_url.?);
            const tags = response.resource.tags.?;
            try expectEqual(@as(usize, 2), tags.len);
            try expectString("market-data", tags[0]);
            try expectString("finance", tags[1]);
            try expectEqual(@as(usize, 1), response.accepts.len);
            try checkRequirements(response.accepts[0]);
            try expectEqual(@as(usize, 0), response.extensions.?.count());
        }
    }.check);
}

test "PaymentRequired.parse returns OutOfMemory with a 64-byte buffer" {
    const input =
        \\{
        \\  "x402Version": 2,
        \\  "resource": {
        \\    "url": "https://api.example.com/premium-data"
        \\  },
        \\  "accepts": []
        \\}
    ;

    var storage: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.OutOfMemory,
        PaymentRequired.parse(fba.allocator(), &reader, .{}),
    );
}

test "spec v2 section 5.2.1: PaymentPayload" {
    const input =
        \\{
        \\  "x402Version": 2,
        \\  "resource": {
        \\    "url": "https://api.example.com/premium-data",
        \\    "description": "Access to premium market data",
        \\    "mimeType": "application/json"
        \\  },
        \\  "accepted": {
        \\    "scheme": "exact",
        \\    "network": "eip155:84532",
        \\    "amount": "10000",
        \\    "asset": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        \\    "payTo": "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
        \\    "maxTimeoutSeconds": 60,
        \\    "extra": {
        \\      "name": "USDC",
        \\      "version": "2"
        \\    }
        \\  },
        \\  "payload": {
        \\    "signature": "0x2d6a7588d6acca505cbf0d9a4a227e0c52c6c34008c8e8986a1283259764173608a2ce6496642e377d6da8dbbf5836e9bd15092f9ecab05ded3d6293af148b571c",
        \\    "authorization": {
        \\      "from": "0x857b06519E91e3A54538791bDbb0E22373e36b66",
        \\      "to": "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
        \\      "value": "10000",
        \\      "validAfter": "1740672089",
        \\      "validBefore": "1740672154",
        \\      "nonce": "0xf3746613c2d920b5fdabc0856f2aeb2d4f88ee6037b8cc5d04a71a4462f13480"
        \\    }
        \\  },
        \\  "extensions": {}
        \\}
    ;

    try checkExample(PaymentPayload, input, struct {
        fn check(response: PaymentPayload) !void {
            try expectEqual(@as(u8, 2), response.x402_version);
            const resource = response.resource.?;
            try checkResource(resource);
            try expect(resource.service_name == null);
            try expect(resource.tags == null);
            try expect(resource.icon_url == null);
            try checkRequirements(response.accepted);
            try expectString("0x2d6a7588d6acca505cbf0d9a4a227e0c52c6c34008c8e8986a1283259764173608a2ce6496642e377d6da8dbbf5836e9bd15092f9ecab05ded3d6293af148b571c", response.payload.get("signature").?.string);
            try checkAuthorization(response.payload, "0x857b06519E91e3A54538791bDbb0E22373e36b66", "0x209693Bc6afc0C5328bA36FaF03C514EF312287C", "0xf3746613c2d920b5fdabc0856f2aeb2d4f88ee6037b8cc5d04a71a4462f13480");
            try expectEqual(@as(usize, 0), response.extensions.?.count());
        }
    }.check);
}

test "spec v2 section 5.3.1: SettleResponse" {
    const input =
        \\{
        \\  "success": true,
        \\  "transaction": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        \\  "network": "eip155:84532",
        \\  "payer": "0x857b06519E91e3A54538791bDbb0E22373e36b66"
        \\}
    ;

    try checkExample(SettleResponse, input, struct {
        fn check(response: SettleResponse) !void {
            try checkSettlement(response, true);
        }
    }.check);
}

// Section 7.1 request template is intentionally skipped: its comments
// stand in for nested messages, so it is not a complete JSON example.

// Section 7.1 complete verify request is deferred until a public request type exists.

test "spec v2 section 7.1: successful verify response" {
    const input =
        \\{
        \\  "isValid": true,
        \\  "payer": "0x857b06519E91e3A54538791bDbb0E22373e36b66"
        \\}
    ;

    try checkExample(VerifyResponse, input, struct {
        fn check(response: VerifyResponse) !void {
            try expect(response.is_valid);
            try expectString("0x857b06519E91e3A54538791bDbb0E22373e36b66", response.payer.?);
            try expect(response.invalid_reason == null);
            try expect(response.extensions == null);
            try expect(response.extra == null);
        }
    }.check);
}

test "spec v2 section 7.1: failed verify response" {
    const input =
        \\{
        \\  "isValid": false,
        \\  "invalidReason": "insufficient_funds",
        \\  "payer": "0x857b06519E91e3A54538791bDbb0E22373e36b66"
        \\}
    ;

    try checkExample(VerifyResponse, input, struct {
        fn check(response: VerifyResponse) !void {
            try expect(!response.is_valid);
            try expectString("insufficient_funds", response.invalid_reason.?);
            try expectString("0x857b06519E91e3A54538791bDbb0E22373e36b66", response.payer.?);
            try expect(response.extensions == null);
            try expect(response.extra == null);
        }
    }.check);
}

test "spec v2 section 7.2: successful settle response" {
    const input =
        \\{
        \\  "success": true,
        \\  "payer": "0x857b06519E91e3A54538791bDbb0E22373e36b66",
        \\  "transaction": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
        \\  "network": "eip155:84532"
        \\}
    ;

    try checkExample(SettleResponse, input, struct {
        fn check(response: SettleResponse) !void {
            try checkSettlement(response, true);
        }
    }.check);
}

test "spec v2 section 7.2: failed settle response" {
    const input =
        \\{
        \\  "success": false,
        \\  "errorReason": "insufficient_funds",
        \\  "payer": "0x857b06519E91e3A54538791bDbb0E22373e36b66",
        \\  "transaction": "",
        \\  "network": "eip155:84532"
        \\}
    ;

    try checkExample(SettleResponse, input, struct {
        fn check(response: SettleResponse) !void {
            try checkSettlement(response, false);
        }
    }.check);
}

// Section 7.3 supported response and section 8.1 discovery response are
// deferred until their public types exist.
