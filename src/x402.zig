//! Core types and operations for the x402 protocol

const std = @import("std");
pub const ResourceInfo = @import("x402/ResourceInfo.zig");

test {
    std.testing.refAllDecls(@This());
}
