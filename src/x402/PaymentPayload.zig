//! An object describing the client payment message.
//!
//! Specification: x402 v2, 5.2.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions borrow caller-owned memory,
//! which must remain valid while the payment message is in use.

const std = @import("std");
const ResourceInfo = @import("ResourceInfo.zig");
const PaymentRequirements = @import("PaymentRequirements.zig");

const PaymentPayload = @This();

// Fields.

/// Protocol version identifier.
x402_version: u8,

/// ResourceInfo object describing the resource being accessed.
resource: ?ResourceInfo = null,

/// Payment requirement object indicating the payment method chosen.
accepted: PaymentRequirements,

/// Scheme-specific payment data.
payload: std.json.ObjectMap,

/// Protocol extensions data.
extensions: ?std.json.ObjectMap = null,

pub const LimitError = ResourceInfo.LimitError || PaymentRequirements.LimitError || error{
    PayloadTooLong,
    TooManyExtensions,
    ExtensionsTooLong,
};

///  Library default limits for collection counts and decoded UTF-8 string bytes.
pub const Limits = struct {
    resource: ResourceInfo.Limits = .{},
    accepted: PaymentRequirements.Limits = .{},

    /// Maximum total UTF-8 bytes of decoded keys and string values in payload.
    max_payload_string_bytes: usize = 16 * 1024,

    max_extensions: usize = 16,

    /// Maximum total UTF-8 bytes of decoded keys and values in extensions.
    max_extensions_string_bytes: usize = 16 * 1024,

    /// Maximum byte length for all decoded string values.
    pub fn maxStringBytes(limits: Limits) error{Overflow}!usize {
        var total: usize = try limits.resource.maxStringBytes();
        total = try std.math.add(usize, total, try limits.accepted.maxStringBytes());
        total = try std.math.add(usize, total, limits.max_payload_string_bytes);
        if (limits.max_extensions > 0) {
            total = try std.math.add(usize, total, limits.max_extensions_string_bytes);
        }
        return total;
    }
};
