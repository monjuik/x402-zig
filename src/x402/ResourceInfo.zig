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
