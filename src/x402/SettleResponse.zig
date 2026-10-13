//! An object with transaction details after payment settlement
//!
//! Specification: x402 v2, 5.3.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions borrow caller-owned memory,
//! which must remain valid while the settlement response is in use.

const std = @import("std");
const json_limits = @import("json_limits.zig");
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

pub fn validate(self: SettleResponse) error{MissingTransaction}!void {
    if (self.error_reason) |reason| {
        // according to 5.3.2 Field Descriptions
        // `transaction` MUST be non-empty when `errorReason` is `settlement_pending`
        if (std.mem.eql(u8, reason, "settlement_pending") and self.transaction.len == 0)
            return error.MissingTransaction;
    }
}

pub const LimitError = error{
    ErrorReasonTooLong,
    PayerTooLong,
    TransactionTooLong,
    NetworkTooLong,
    AmountTooLong,
    TooManyExtensions,
    ExtensionsTooLong,
};

/// Library default limits for decoded strings, measured in UTF-8 bytes.
pub const Limits = struct {
    max_error_reason_bytes: usize = 4096,
    max_payer_bytes: usize = 256,
    max_transaction_bytes: usize = 256,
    max_amount_bytes: usize = 128,

    max_extensions: usize = 16,
    /// Maximum total UTF-8 bytes of decoded keys and values in extensions.
    max_extensions_string_bytes: usize = 16 * 1024,

    /// Maximum byte length for all decoded string values.
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = Network.max_network_bytes;
        total = try std.math.add(usize, total, limits.max_error_reason_bytes);
        total = try std.math.add(usize, total, limits.max_payer_bytes);
        total = try std.math.add(usize, total, limits.max_transaction_bytes);
        total = try std.math.add(usize, total, limits.max_amount_bytes);

        if (limits.max_extensions > 0) {
            total = try std.math.add(usize, total, limits.max_extensions_string_bytes);
        }

        return total;
    }

    pub fn check(limits: Limits, response: SettleResponse) LimitError!void {
        if (response.error_reason) |reason| {
            if (reason.len > limits.max_error_reason_bytes)
                return error.ErrorReasonTooLong;
        }

        if (response.payer) |payer| {
            if (payer.len > limits.max_payer_bytes)
                return error.PayerTooLong;
        }

        if (response.transaction.len > limits.max_transaction_bytes)
            return error.TransactionTooLong;

        if (response.network.bytes.len > Network.max_network_bytes)
            return error.NetworkTooLong;

        if (response.amount) |amount| {
            if (amount.bytes.len > limits.max_amount_bytes)
                return error.AmountTooLong;
        }

        if (response.extensions) |extensions| {
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
) !SettleResponse {
    const response = try json_parse.parse(SettleResponse, allocator, reader);
    try response.validate();

    try options.limits.check(response); // yes, we already used the memory.
    // But this allows us to use standard parser

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

test "Limits.maxStringBytes handles custom limits and overflow" {
    var limits: Limits = .{
        .max_error_reason_bytes = 1,
        .max_payer_bytes = 2,
        .max_transaction_bytes = 3,
        .max_amount_bytes = 4,
        .max_extensions = 2,
        .max_extensions_string_bytes = 5,
    };
    try std.testing.expectEqual(@as(usize, 56), try limits.maxStringBytes());

    const max = std.math.maxInt(usize);

    limits.max_extensions = 0;
    limits.max_extensions_string_bytes = max;
    try std.testing.expectEqual(@as(usize, 51), try limits.maxStringBytes());

    limits = .{
        .max_error_reason_bytes = max - Network.max_network_bytes,
        .max_payer_bytes = 0,
        .max_transaction_bytes = 0,
        .max_amount_bytes = 0,
        .max_extensions = 1,
        .max_extensions_string_bytes = 0,
    };
    try std.testing.expectEqual(max, try limits.maxStringBytes());

    limits.max_extensions_string_bytes = 1;
    try std.testing.expectError(error.Overflow, limits.maxStringBytes());

    const cases = [_]Limits{
        .{ .max_error_reason_bytes = max },
        .{ .max_payer_bytes = max },
        .{ .max_transaction_bytes = max },
        .{ .max_amount_bytes = max },
        .{ .max_extensions_string_bytes = max },
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
        .max_error_reason_bytes = 3,
        .max_payer_bytes = 2,
        .max_transaction_bytes = 4,
        .max_amount_bytes = 1,
        .max_extensions = 1,
        .max_extensions_string_bytes = 3,
    };
    const response: SettleResponse = .{
        .success = false,
        .error_reason = "err",
        .payer = "pp",
        .transaction = "tttt",
        .network = try Network.parse("chainstd:8c3444cf8970a9e41a706fab93e7a6c4"),
        .amount = try Amount.parse("1"),
        .extensions = parsed.value.object,
    };
    try limits.check(response);

    const cases = .{
        .{ "error_reason", 3, error.ErrorReasonTooLong },
        .{ "payer", 2, error.PayerTooLong },
        .{ "transaction", 4, error.TransactionTooLong },
    };
    inline for (cases) |case| {
        var oversized = response;
        @field(oversized, case[0]) =
            &@as([case[1] + 1]u8, @splat('x'));
        try std.testing.expectError(case[2], limits.check(oversized));
    }

    // Deliberately bypass parse to test the length guard independently.
    var oversized_network = response;
    oversized_network.network = .{
        .bytes = &@as([Network.max_network_bytes + 1]u8, @splat('x')),
    };
    try std.testing.expectError(error.NetworkTooLong, limits.check(oversized_network));

    var oversized_amount = response;
    oversized_amount.amount = try Amount.parse("12");
    try std.testing.expectError(
        error.AmountTooLong,
        limits.check(oversized_amount),
    );

    const extension_cases = .{
        .{ "max_extensions", 0, error.TooManyExtensions },
        .{ "max_extensions_string_bytes", 2, error.ExtensionsTooLong },
    };
    inline for (extension_cases) |case| {
        var reduced = limits;
        @field(reduced, case[0]) = case[1];
        try std.testing.expectError(case[2], reduced.check(response));
    }

    const zero_limits: Limits = .{
        .max_error_reason_bytes = 0,
        .max_payer_bytes = 0,
        .max_transaction_bytes = 0,
        .max_amount_bytes = 0,
        .max_extensions = 0,
        .max_extensions_string_bytes = 0,
    };
    var empty: SettleResponse = .{
        .success = true,
        .transaction = "",
        .network = try Network.parse("eip155:1"),
    };

    // Absent and empty optional fields fit zero budgets.
    try zero_limits.check(empty);
    empty.error_reason = "";
    empty.payer = "";
    empty.extensions = .{};
    try zero_limits.check(empty);

    empty.amount = try Amount.parse("0");
    try std.testing.expectError(
        error.AmountTooLong,
        zero_limits.check(empty),
    );
}

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

    const response = try SettleResponse.parse(fba.allocator(), &reader, .{});

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
            SettleResponse.parse(fba.allocator(), &reader, .{}),
        );
    }
}

test "parse enforces custom limits" {
    var storage: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(
        \\{"success":true,"transaction":"abcd","network":"eip155:1"}
    );

    try std.testing.expectError(
        error.TransactionTooLong,
        SettleResponse.parse(fba.allocator(), &reader, .{
            .limits = .{ .max_transaction_bytes = 3 },
        }),
    );
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
            .{},
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
            SettleResponse.parse(fba.allocator(), &reader, .{}),
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
        SettleResponse.parse(fba.allocator(), &reader, .{}),
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

        _ = try SettleResponse.parse(fba.allocator(), &reader, .{});
    }
}
