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
const json_limits = @import("json_limits.zig");
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

pub const LimitError = ResourceInfo.LimitError || PaymentRequirements.LimitError || error{
    ErrorTooLong,
    TooManyAccepts,
    TooManyExtensions,
    ExtensionsTooLong,
};

///  Library default limits for collection counts and decoded UTF-8 string bytes.
pub const Limits = struct {
    resource: ResourceInfo.Limits = .{},
    requirements: PaymentRequirements.Limits = .{},

    max_error_bytes: usize = 4096,
    max_accepts: usize = 16,
    max_extensions: usize = 16,

    /// Maximum total UTF-8 bytes of decoded keys and values in extensions.
    max_extensions_string_bytes: usize = 16 * 1024,

    /// Maximum byte length for all decoded string values.
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = try limits.resource.maxStringBytes();
        total = try std.math.add(usize, total, limits.max_error_bytes);
        if (limits.max_accepts > 0) {
            const requirements = try limits.requirements.maxStringBytes();
            const accepts = try std.math.mul(usize, limits.max_accepts, requirements);
            total = try std.math.add(usize, total, accepts);
        }
        if (limits.max_extensions > 0) {
            total = try std.math.add(usize, total, limits.max_extensions_string_bytes);
        }
        return total;
    }

    /// Checks decoded string sizes against the limits.
    pub fn check(limits: Limits, response: PaymentRequired) LimitError!void {
        if (response.@"error") |message| {
            if (message.len > limits.max_error_bytes)
                return error.ErrorTooLong;
        }

        if (response.accepts.len > limits.max_accepts)
            return error.TooManyAccepts;

        try limits.resource.check(response.resource);

        for (response.accepts) |requirements| {
            try limits.requirements.check(requirements);
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
) !PaymentRequired {
    const response = try json_parse.parse(PaymentRequired, allocator, reader);
    try options.limits.check(response);
    return response;
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

test "Limits.maxStringBytes handles custom limits and overflow" {
    var limits: Limits = .{
        .resource = .{ .max_url_bytes = 17 },
        .requirements = .{ .max_scheme_bytes = 19 },
        .max_error_bytes = 7,
        .max_accepts = 3,
        .max_extensions = 2,
        .max_extensions_string_bytes = 11,
    };
    const resource = try limits.resource.maxStringBytes();
    const requirements = try limits.requirements.maxStringBytes();

    try std.testing.expectEqual(
        resource + 7 + 3 * requirements + 11,
        try limits.maxStringBytes(),
    );

    const max = std.math.maxInt(usize);
    limits.max_accepts = 0;
    limits.requirements.max_extra_string_bytes = max;
    limits.max_extensions = 0;
    limits.max_extensions_string_bytes = max;
    try std.testing.expectEqual(resource + 7, try limits.maxStringBytes());

    const default_resource = try (ResourceInfo.Limits{}).maxStringBytes();
    const cases = [_]Limits{
        .{ .max_error_bytes = max },
        .{ .max_accepts = max },
        .{
            .max_error_bytes = max - default_resource,
            .max_accepts = 1,
            .max_extensions = 0,
        },
        .{ .max_extensions_string_bytes = max },
    };
    for (cases) |case| {
        try std.testing.expectError(error.Overflow, case.maxStringBytes());
    }
}

test "Limits.check accepts boundaries and identifies exceeded fields" {
    const requirements: PaymentRequirements = .{
        .scheme = "sss",
        .network = "eip155:1",
        .amount = "1",
        .asset = "asset",
        .pay_to = "recipient",
        .max_timeout_seconds = 60,
    };
    var accepts = [_]PaymentRequirements{ requirements, requirements };
    accepts[0].scheme = "s";

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"x":null}
    , .{});
    defer parsed.deinit();

    const response: PaymentRequired = .{
        .x402_version = 2,
        .@"error" = "err",
        .resource = .{ .url = "url" },
        .accepts = &accepts,
        .extensions = parsed.value.object,
    };
    const limits: Limits = .{
        .resource = .{ .max_url_bytes = 3 },
        .requirements = .{ .max_scheme_bytes = 3 },
        .max_error_bytes = 3,
        .max_accepts = 2,
        .max_extensions = 1,
        .max_extensions_string_bytes = 1,
    };
    try limits.check(response);

    const cases = .{
        .{ Limits{ .max_error_bytes = 2 }, error.ErrorTooLong },
        .{ Limits{ .max_accepts = 1 }, error.TooManyAccepts },
        .{ Limits{ .max_extensions = 0 }, error.TooManyExtensions },
        .{ Limits{ .max_extensions_string_bytes = 0 }, error.ExtensionsTooLong },
        .{ Limits{ .resource = .{ .max_url_bytes = 2 } }, error.UrlTooLong },
        .{ Limits{ .requirements = .{ .max_scheme_bytes = 2 } }, error.SchemeTooLong },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[1], case[0].check(response));
    }
    var empty: PaymentRequired = .{
        .x402_version = 2,
        .resource = .{ .url = "url" },
        .accepts = &.{},
    };
    const zero_limits: Limits = .{
        .max_error_bytes = 0,
        .max_accepts = 0,
        .max_extensions = 0,
        .max_extensions_string_bytes = 0,
    };

    // Absent and empty optional fields fit zero budgets.
    try zero_limits.check(empty);
    empty.@"error" = "";
    empty.extensions = .{};
    try zero_limits.check(empty);

    const nested = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"a":{"b":null}}
    , .{});
    defer nested.deinit();
    empty.extensions = nested.value.object;

    // Nested keys do not count as top-level extensions.
    var nested_limits = zero_limits;
    nested_limits.max_extensions = 1;
    nested_limits.max_extensions_string_bytes = 2;
    try nested_limits.check(empty);
}

test "jsonStringify writes nested payment requirements and optional fields" {
    var response: PaymentRequired = .{
        .x402_version = 2,
        .resource = .{ .url = "url" },
        .accepts = &.{.{
            .scheme = "exact",
            .network = "eip155:1",
            .amount = "100",
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

    const response = try PaymentRequired.parse(fba.allocator(), &reader, .{});

    try std.testing.expectEqual(@as(u8, 2), response.x402_version);
    try std.testing.expectEqualStrings("Payment required", response.@"error".?);
    try std.testing.expectEqualStrings("url", response.resource.url);
    try std.testing.expectEqualStrings(
        "application/json",
        response.resource.mime_type.?,
    );

    try std.testing.expectEqual(@as(usize, 1), response.accepts.len);
    try std.testing.expectEqualStrings("recipient", response.accepts[0].pay_to);

    const extensions = response.extensions.?;
    try std.testing.expectEqual(@as(usize, 1), extensions.count());
    try std.testing.expect(extensions.get("example").?.bool);
}

test "parse enforces custom nested limits" {
    const input =
        \\{"x402Version":2,"resource":{"url":"abcd"},"accepts":[]}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    try std.testing.expectError(
        error.UrlTooLong,
        PaymentRequired.parse(fba.allocator(), &reader, .{
            .limits = .{
                .resource = .{ .max_url_bytes = 3 },
            },
        }),
    );
}
