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

            var remaining = limits.max_extensions_string_bytes;
            try checkExtensionStrings(.{ .object = extensions }, &remaining);
        }
    }

    fn checkExtensionStrings(value: std.json.Value, remaining: *usize) LimitError!void {
        switch (value) {
            .string => |string| try consumeExtensionBytes(string.len, remaining),
            .object => |object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    try consumeExtensionBytes(entry.key_ptr.*.len, remaining);
                    try checkExtensionStrings(entry.value_ptr.*, remaining);
                }
            },
            .array => |array| {
                for (array.items) |item| {
                    try checkExtensionStrings(item, remaining);
                }
            },
            else => {},
        }
    }

    fn consumeExtensionBytes(bytes: usize, remaining: *usize) LimitError!void {
        if (bytes > remaining.*)
            return error.ExtensionsTooLong;

        remaining.* -= bytes;
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
}

test "Limits.check counts decoded extension keys and strings recursively" {
    var response: PaymentRequired = .{
        .x402_version = 2,
        .resource = .{ .url = "url" },
        .accepts = &.{},
    };
    var limits: Limits = .{
        .max_error_bytes = 0,
        .max_accepts = 0,
        .max_extensions = 0,
        .max_extensions_string_bytes = 0,
    };

    // Absent and empty optional fields fit zero budgets.
    try limits.check(response);
    response.@"error" = "";
    response.extensions = .{};
    try limits.check(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"\u00e9":["\u00e9",{"b":"x"}],"c":[1,true,null]}
    , .{});
    defer parsed.deinit();
    response.extensions = parsed.value.object;

    // Two top-level extensions; nested keys do not affect their count.
    // Decoded keys: 2 + 1 + 1 = 4 bytes. String values: 2 + 1 = 3 bytes.
    limits.max_extensions = 2;
    limits.max_extensions_string_bytes = 7;
    try limits.check(response);

    limits.max_extensions_string_bytes = 6;
    try std.testing.expectError(error.ExtensionsTooLong, limits.check(response));
}
