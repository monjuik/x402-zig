//! An object describing the protected resource.
//!
//! Specification: x402 v2, 5.1.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices borrow caller-owned memory, which must remain valid while the resource information is in use.

const std = @import("std");

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

pub const LimitError = error{
    UrlTooLong,
    DescriptionTooLong,
    MimeTypeTooLong,
    ServiceNameTooLong,
    TooManyTags,
    TagTooLong,
    IconUrlTooLong,
};

/// Library default limits for decoded strings, measured in UTF-8 bytes.
pub const Limits = struct {
    max_url_bytes: usize = 2048,
    max_description_bytes: usize = 4096,
    max_mime_type_bytes: usize = 256, // RFC 4288, https://datatracker.ietf.org/doc/html/rfc4288#section-4.2

    /// Maximum byte length for all decoded string values
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = max_service_name_bytes +
            max_tags * max_tag_bytes +
            max_icon_url_bytes;

        total = try std.math.add(usize, total, limits.max_url_bytes);
        total = try std.math.add(usize, total, limits.max_description_bytes);
        total = try std.math.add(usize, total, limits.max_mime_type_bytes);

        return total;
    }

    /// Checks existing ResourceInfo against the limits
    pub fn check(limits: Limits, resource: ResourceInfo) LimitError!void {
        if (resource.url.len > limits.max_url_bytes)
            return LimitError.UrlTooLong;

        if (resource.description) |value| {
            if (value.len > limits.max_description_bytes)
                return LimitError.DescriptionTooLong;
        }

        if (resource.mime_type) |value| {
            if (value.len > limits.max_mime_type_bytes)
                return LimitError.MimeTypeTooLong;
        }

        if (resource.service_name) |value| {
            if (value.len > max_service_name_bytes)
                return LimitError.ServiceNameTooLong;
        }

        if (resource.tags) |tags| {
            if (tags.len > max_tags)
                return LimitError.TooManyTags;

            for (tags) |tag| {
                if (tag.len > max_tag_bytes)
                    return LimitError.TagTooLong;
            }
        }

        if (resource.icon_url) |value| {
            if (value.len > max_icon_url_bytes)
                return LimitError.IconUrlTooLong;
        }
    }
};

test "Limits.maxStringBytes uses custom limits" {
    const limits: Limits = .{
        .max_url_bytes = 1,
        .max_description_bytes = 10,
        .max_mime_type_bytes = 100,
    };

    // Configurable fields: 1 + 10 + 100 = 111.
    // Others: 32 + 5 * 32 + 2048 = 2240.
    try std.testing.expectEqual(
        @as(usize, 2351),
        try limits.maxStringBytes(),
    );
}

test "Limits.maxStringBytes accepts the largest representable total" {
    const fixed_bytes: usize = 2240;
    const limits: Limits = .{
        .max_url_bytes = std.math.maxInt(usize) - fixed_bytes,
        .max_description_bytes = 0,
        .max_mime_type_bytes = 0,
    };

    try std.testing.expectEqual(
        std.math.maxInt(usize),
        try limits.maxStringBytes(),
    );
}

test "Limits.maxStringBytes rejects too large limits" {
    const fixed_bytes: usize = 2240;
    const limits: Limits = .{
        .max_url_bytes = std.math.maxInt(usize) - fixed_bytes,
        .max_description_bytes = 0,
        .max_mime_type_bytes = 1,
    };

    try std.testing.expectError(
        error.Overflow,
        limits.maxStringBytes(),
    );
}

test "Limits.check accepts all fields at their limits" {
    const limits: Limits = .{
        .max_url_bytes = 3,
        .max_description_bytes = 3,
        .max_mime_type_bytes = 3,
    };

    const resource: ResourceInfo = .{
        .url = "a.a",
        .description = "aaa",
        .mime_type = "mmm",
        .service_name = &@as([32]u8, @splat('s')),
        .tags = &.{
            &@as([32]u8, @splat('a')),
            &@as([32]u8, @splat('b')),
            &@as([32]u8, @splat('c')),
            &@as([32]u8, @splat('d')),
            &@as([32]u8, @splat('e')),
        },
        .icon_url = &@as([2048]u8, @splat('u')),
    };
    try limits.check(resource);
}

test "Limits.check identifies every exceeded limit" {
    const limits: Limits = .{
        .max_url_bytes = 3,
        .max_description_bytes = 4,
        .max_mime_type_bytes = 5,
    };

    const Case = struct {
        resource: ResourceInfo,
        expected: LimitError,
    };

    const cases = [_]Case{
        .{
            .resource = .{ .url = "uuuu" },
            .expected = LimitError.UrlTooLong,
        },
        .{
            .resource = .{
                .url = "uuu",
                .description = "descr",
            },
            .expected = LimitError.DescriptionTooLong,
        },
        .{
            .resource = .{
                .url = "uuu",
                .mime_type = "mime/t",
            },
            .expected = LimitError.MimeTypeTooLong,
        },
        .{
            .resource = .{
                .url = "uuu",
                .service_name = &@as([33]u8, @splat('n')),
            },
            .expected = LimitError.ServiceNameTooLong,
        },
        .{
            .resource = .{
                .url = "uuu",
                .tags = &.{ "a", "b", "c", "d", "e", "f" },
            },
            .expected = LimitError.TooManyTags,
        },
        .{
            .resource = .{
                .url = "uuu",
                .tags = &.{ "a", "b", "c", "d", &@as([33]u8, @splat('e')) },
            },
            .expected = LimitError.TagTooLong,
        },
        .{
            .resource = .{
                .url = "uuu",
                .icon_url = &@as([2049]u8, @splat('u')),
            },
            .expected = LimitError.IconUrlTooLong,
        },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, limits.check(case.resource));
    }
}
