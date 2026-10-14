//! An object describing the protected resource.
//!
//! Specification: x402 v2, 5.1.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices borrow caller-owned memory, which must remain valid while the resource information is in use.

const std = @import("std");
const json_parse = @import("json_parse.zig");

const ResourceInfo = @This();

// Fields.

/// URL of the protected resource.
url: []const u8,

/// Human-readable description of the resource.
description: ?[]const u8 = null,

/// MIME type of the expected response.
mime_type: ?[]const u8 = null,

/// Human-readable name of the service hosting the resource. Printable ASCII, max 32 characters.
service_name: ?[]const u8 = null,

/// Topical tags for the service, used for discovery filtering. Max 5 entries; each printable ASCII, max 32 characters.
tags: ?[]const []const u8 = null,

/// Absolute https/http URL to an icon representing the service. Max 2048 characters.
icon_url: ?[]const u8 = null,

// Specification limits.
pub const max_service_name_bytes = 32;
pub const max_tags = 5;
pub const max_tag_bytes = 32;
pub const max_icon_url_bytes = 2048;

pub fn jsonStringify(self: ResourceInfo, jw: anytype) !void {
    try jw.beginObject();

    try jw.objectField("url");
    try jw.write(self.url);

    if (self.description) |value| {
        try jw.objectField("description");
        try jw.write(value);
    }

    if (self.mime_type) |value| {
        try jw.objectField("mimeType");
        try jw.write(value);
    }

    if (self.service_name) |value| {
        try jw.objectField("serviceName");
        try jw.write(value);
    }

    if (self.tags) |value| {
        try jw.objectField("tags");
        try jw.write(value);
    }

    if (self.icon_url) |value| {
        try jw.objectField("iconUrl");
        try jw.write(value);
    }

    try jw.endObject();
}

pub const ValidationError = error{
    ServiceNameTooLong,
    TooManyTags,
    TagTooLong,
    IconUrlTooLong,
};

pub fn validate(self: ResourceInfo) ValidationError!void {
    if (self.service_name) |value| {
        if (value.len > max_service_name_bytes)
            return error.ServiceNameTooLong;
    }

    if (self.tags) |tags| {
        if (tags.len > max_tags)
            return error.TooManyTags;

        for (tags) |tag| {
            if (tag.len > max_tag_bytes)
                return error.TagTooLong;
        }
    }

    if (self.icon_url) |value| {
        if (value.len > max_icon_url_bytes)
            return error.IconUrlTooLong;
    }
}

/// Reads one JSON object. Pass a reader bounded to this message.
pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !ResourceInfo {
    const resource = try json_parse.parse(ResourceInfo, allocator, reader);
    try resource.validate();

    return resource;
}

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !ResourceInfo {
    const json = try std.json.innerParse(Json, allocator, source, options);
    return json.toResourceInfo();
}

const Json = struct {
    url: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    serviceName: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    iconUrl: ?[]const u8 = null,

    fn toResourceInfo(self: Json) ResourceInfo {
        return .{
            .url = self.url,
            .description = self.description,
            .mime_type = self.mimeType,
            .service_name = self.serviceName,
            .tags = self.tags,
            .icon_url = self.iconUrl,
        };
    }
};

test "jsonStringify writes protocol fields and omits absent optionals" {
    var buffer: [1024]u8 = undefined;

    {
        var writer: std.Io.Writer = .fixed(&buffer);
        const resource: ResourceInfo = .{ .url = "https://example.com" };

        try std.json.Stringify.value(resource, .{}, &writer);

        try std.testing.expectEqualStrings(
            \\{"url":"https://example.com"}
        , writer.buffered());
    }

    {
        var writer: std.Io.Writer = .fixed(&buffer);
        const resource: ResourceInfo = .{
            .url = "https://example.com",
            .description = "",
            .mime_type = "application/json",
            .service_name = "Example",
            .tags = &.{ "api", "paid" },
            .icon_url = "https://example.com/icon.png",
        };

        try std.json.Stringify.value(resource, .{}, &writer);

        try std.testing.expectEqualStrings(
            \\{"url":"https://example.com","description":"","mimeType":"application/json","serviceName":"Example","tags":["api","paid"],"iconUrl":"https://example.com/icon.png"}
        , writer.buffered());
    }
}

test "parse maps protocol fields to ResourceInfo" {
    const input =
        \\{"url":"url","description":"description","mimeType":"application/json","serviceName":"Example","tags":["api","paid"],"iconUrl":"icon","unknown":{"value":1}}
    ;

    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(input);

    const resource = try ResourceInfo.parse(fba.allocator(), &reader);

    try std.testing.expectEqualStrings("url", resource.url);
    try std.testing.expectEqualStrings("description", resource.description.?);
    try std.testing.expectEqualStrings("application/json", resource.mime_type.?);
    try std.testing.expectEqualStrings("Example", resource.service_name.?);
    try std.testing.expectEqual(@as(usize, 2), resource.tags.?.len);
    try std.testing.expectEqualStrings("api", resource.tags.?[0]);
    try std.testing.expectEqualStrings("paid", resource.tags.?[1]);
    try std.testing.expectEqualStrings("icon", resource.icon_url.?);
}

test "validate accepts metadata at specification boundaries" {
    const resource: ResourceInfo = .{
        .url = "url",
        .service_name = &@as([max_service_name_bytes]u8, @splat('s')),
        .tags = &@as([max_tags][]const u8, @splat(&@as([max_tag_bytes]u8, @splat('t')))),
        .icon_url = &@as([max_icon_url_bytes]u8, @splat('u')),
    };
    try resource.validate();
}

test "parse enforces specification metadata limits" {
    const Case = struct { resource: ResourceInfo, expected: ValidationError };
    const cases = [_]Case{
        .{ .resource = .{ .url = "url", .service_name = &@as([max_service_name_bytes + 1]u8, @splat('s')) }, .expected = error.ServiceNameTooLong },
        .{ .resource = .{ .url = "url", .tags = &@as([max_tags + 1][]const u8, @splat("tag")) }, .expected = error.TooManyTags },
        .{ .resource = .{ .url = "url", .tags = &.{&@as([max_tag_bytes + 1]u8, @splat('t'))} }, .expected = error.TagTooLong },
        .{ .resource = .{ .url = "url", .icon_url = &@as([max_icon_url_bytes + 1]u8, @splat('u')) }, .expected = error.IconUrlTooLong },
    };
    for (cases) |case| {
        var input: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&input);
        try std.json.Stringify.value(case.resource, .{}, &writer);
        var storage: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        try std.testing.expectError(case.expected, ResourceInfo.parse(fba.allocator(), &reader));
    }
}

test "parse accepts fields beyond former library size limits" {
    const resource: ResourceInfo = .{
        .url = &@as([2049]u8, @splat('u')),
        .description = &@as([4097]u8, @splat('d')),
        .mime_type = &@as([257]u8, @splat('m')),
    };
    var input: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&input);
    try std.json.Stringify.value(resource, .{}, &writer);
    var storage: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    const parsed = try ResourceInfo.parse(fba.allocator(), &reader);
    try std.testing.expectEqualStrings(resource.url, parsed.url);
    try std.testing.expectEqualStrings(resource.description.?, parsed.description.?);
    try std.testing.expectEqualStrings(resource.mime_type.?, parsed.mime_type.?);
}
