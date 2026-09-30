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

pub const LimitError = error{
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
};
