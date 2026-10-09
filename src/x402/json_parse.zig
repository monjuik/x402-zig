//! Common functions for parsing JSON.

const std = @import("std");

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicate_field_behavior = .@"error",
    .allocate = .alloc_always,
    .max_value_len = std.math.maxInt(usize),
};

pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !T {
    var source = std.json.Reader.init(allocator, reader);
    defer source.deinit();

    return try std.json.parseFromTokenSourceLeaky(T, allocator, &source, parse_options);
}
