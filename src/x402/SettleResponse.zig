//! An object with transaction details after payment settlement
//!
//! Specification: x402 v2, 5.3.2 Field Descriptions
//! https://github.com/x402-foundation/x402/blob/main/specs/x402-specification-v2.md
//!
//! Slices and storage for extensions borrow caller-owned memory,
//! which must remain valid while the settlement response is in use.

const std = @import("std");

const SettleResponse = @This();

// Fields.

/// Indicates whether the payment settlement was successful.
success: bool,

/// Error reason if settlement failed (omitted if successful).
error_reason: ?[]const u8 = null,

/// Address of the payer’s wallet.
payer: ?[]const u8 = null,

/// Blockchain transaction hash (empty string if no transaction was broadcast;
/// MUST be non-empty when errorReason is settlement_pending).
transaction: []const u8,

/// Blockchain network identifier in CAIP-2 format.
network: []const u8, // https://github.com/ChainAgnostic/CAIPs/blob/main/CAIPs/caip-2.md

/// The actual amount settled in atomic units (omitted if not applicable).
amount: ?[]const u8 = null,

/// Protocol extensions data.
extensions: ?std.json.ObjectMap = null,

// Specification limits.
pub const max_network_bytes = 41; // inherited from CAIP-2: 8 + 1 + 32 = 41

pub const LimitError = error{
    ErrorReasonTooLong,
    PayerTooLong,
    TransactionTooLong,
    NetworkTooLong,
    AmountTooLong,
    TooManyExtensions,
    ExtensionsTooLong,
};

/// Library default limits for decoded strings, measured in UTF-8 bytes.
pub const Limits = struct {
    max_error_reason_bytes: usize = 4096,
    max_payer_bytes: usize = 256,
    max_transaction_bytes: usize = 256,
    max_amount_bytes: usize = 128,

    max_extensions: usize = 16,
    /// Maximum total UTF-8 bytes of decoded keys and values in extensions.
    max_extensions_string_bytes: usize = 16 * 1024,
};
