//! An object describing the payment requirements.
//!
//! Specification: x402 v2, 5.1.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extra borrow caller-owned memory,
//! which must remain valid while the payment requirements are in use.

const std = @import("std");

const PaymentRequirements = @This();

// Fields.

/// Payment scheme identifier (e.g., “exact”).
scheme: []const u8,

/// Blockchain network identifier in CAIP-2 format (e.g., “eip155:84532”).
network: []const u8, // https://github.com/ChainAgnostic/CAIPs/blob/main/CAIPs/caip-2.md

/// Required payment amount in atomic token units.
amount: []const u8,

/// Token contract address or ISO 4217 currency code for fiat.
asset: []const u8, // ISO 4217 format: three digits or three letters

/// Recipient wallet address or role constant (e.g., “merchant”).
pay_to: []const u8,

/// Maximum time allowed for payment completion.
max_timeout_seconds: u32,

/// Additional information.
/// Reserved protocol keys: assetTransferMethod, paymentFlow; other keys are scheme-specific.
extra: ?std.json.ObjectMap = null,
