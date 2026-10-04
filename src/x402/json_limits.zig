//! Common functions for JSON values

const std = @import("std");

/// Checks decoded string keys and values against max.
pub fn checkStringBytes(value: std.json.Value, max: usize) error{StringBytesExceeded}!void {
    var remaining = max;
    try consumeStrings(value, &remaining);
}

fn consumeStrings(value: std.json.Value, remaining: *usize) error{StringBytesExceeded}!void {
    switch (value) {
        .string => |string| try consumeBytes(string.len, remaining),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try consumeBytes(entry.key_ptr.*.len, remaining);
                try consumeStrings(entry.value_ptr.*, remaining);
            }
        },
        .array => |array| {
            for (array.items) |item| {
                try consumeStrings(item, remaining);
            }
        },
        else => {},
    }
}

fn consumeBytes(bytes: usize, remaining: *usize) error{StringBytesExceeded}!void {
    if (bytes > remaining.*)
        return error.StringBytesExceeded;

    remaining.* -= bytes;
}

test "checkStringBytes counts decoded keys and strings within the budget" {
    const cases = .{
        // Empty strings and containers.
        .{ "\"\"", 0 },
        .{ "{}", 0 },
        .{ "[]", 0 },

        // Non-string values.
        .{ "[123,1.5,true,false,null]", 0 },

        // Root strings, object keys, and object string values.
        .{ "\"abc\"", 3 },
        .{ "{\"abc\":null}", 3 },
        .{ "{\"\":\"abc\"}", 3 },

        // The budget is shared across siblings.
        .{ "[\"ab\",\"cd\"]", 4 },
        .{ "{\"a\":\"b\",\"c\":\"d\"}", 4 },

        // Escaped keys and values are counted as decoded UTF-8.
        .{ "{\"\\u00e9\":\"\\u00e9\"}", 4 },

        // Nested objects and arrays share the same budget.
        .{
            "{\"\\u00e9\":[\"\\u00e9\",{\"b\":\"x\"}],\"c\":[1,true,null]}",
            7,
        },
    };

    inline for (cases) |case| {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            case[0],
            .{},
        );
        defer parsed.deinit();

        const bytes: usize = case[1];

        try checkStringBytes(parsed.value, bytes);
        try checkStringBytes(parsed.value, bytes + 1);

        if (bytes > 0) {
            try std.testing.expectError(
                error.StringBytesExceeded,
                checkStringBytes(parsed.value, bytes - 1),
            );
            try std.testing.expectError(
                error.StringBytesExceeded,
                checkStringBytes(parsed.value, 0),
            );
        }
    }
}
