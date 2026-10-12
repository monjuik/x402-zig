//! Network identifier in CAIP-format (https://github.com/ChainAgnostic/CAIPs/blob/main/CAIPs/caip-2.md).
//! Construct through parse().

pub const std = @import("std");
pub const Network = @This();

bytes: []const u8,

pub const max_network_bytes = 41; // inherited from CAIP-2: 8 + 1 + 32 = 41

/// Parses Network.
/// Input memory must remain valid and unchanged while the network is used.
pub fn parse(bytes: []const u8) error{InvalidNetwork}!Network {
    if (bytes.len < 5 or bytes.len > max_network_bytes)
        return error.InvalidNetwork;

    const separator = std.mem.indexOfScalar(u8, bytes, ':') orelse
        return error.InvalidNetwork;

    const namespace = bytes[0..separator];
    const reference = bytes[separator + 1 ..];

    if (namespace.len < 3 or namespace.len > 8)
        return error.InvalidNetwork;

    if (reference.len == 0 or reference.len > 32)
        return error.InvalidNetwork;

    for (namespace) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-'))
            return error.InvalidNetwork;
    }

    for (reference) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_'))
            return error.InvalidNetwork;
    }

    return .{ .bytes = bytes };
}

pub fn jsonStringify(self: Network, jw: anytype) !void {
    try jw.write(self.bytes);
}

test "parse accepts CAIP-2 identifiers and borrows input" {
    const cases = [_][]const u8{
        "eip155:1",
        "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1",
        "cosmos:Binance-Chain-Tigris",
        "starknet:SN_GOERLI",
        "ach:us",
        "a-0:_",
        "chainstd:8c3444cf8970a9e41a706fab93e7a6c4",
    };

    for (cases) |input| {
        const network = try Network.parse(input);
        try std.testing.expectEqualStrings(input, network.bytes);
        try std.testing.expect(input.ptr == network.bytes.ptr);
    }
}

test "parse rejects invalid CAIP-2 identifiers" {
    const cases = [_][]const u8{
        "",
        "eip155",
        ":1",
        "ab:1",
        "abcdefghi:1",
        "eip155:",
        "abc:123456789012345678901234567890123",
        "EIP155:1",
        "eip_55:1",
        "eip155:1:2",
        "eip155:*",
        "eip155:1.0",
        "eip155:1/2",
        " eip155:1",
        "eip155:1 ",
        "eip155:1\n",
        "eip155:١",
    };

    for (cases) |input| {
        try std.testing.expectError(
            error.InvalidNetwork,
            Network.parse(input),
        );
    }
}

test "jsonStringify writes network as a JSON string" {
    const network = try Network.parse("eip155:84532");

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.json.Stringify.value(network, .{}, &writer);
    try std.testing.expectEqualStrings(
        "\"eip155:84532\"",
        writer.buffered(),
    );
}
