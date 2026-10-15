# x402-zig

An x402 v2 core library for Zig.

## Status

- Types: `done`
- JSON parsing: `done`
- JSON serialization: `done`
- Message validation against spec: `done`

## Supported types

- `PaymentRequired`
- `PaymentRequirements`
- `PaymentPayload`
- `VerifyResponse`
- `SettleResponse`
- `ResourceInfo`
- `Amount`
- `Network`

### Tests

`src/x402/specification_tests.zig` covers complete examples of core entites from the x402 specification.

### Validation

- `validate()` functions apply x402 specification v2 checks.
- `parse(allocator, reader)` functions apply them as well.

## Why I am building this

I believe that resource-efficient software has additional value. This library helps deploying x402 components close to the target services.
It could be used by infrastructure providers such as Cloudflare to offer x402-based payment capabilities to the customers.

## Memory use

Parsing uses the supplied allocator. You can use a `FixedBufferAllocator`:

```zig
const std = @import("std");
const x402 = @import("x402");

pub fn main() !void {
    var storage: [4096]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var reader: std.Io.Reader = .fixed(
        \\{"url":"https://api.example.com/resource"}
    );
    const resource = try x402.ResourceInfo.parse(allocator.allocator(), &reader);
    _ = resource;
}
```

Insufficient storage returns `error.OutOfMemory`. The buffer must remain valid while parsed strings and collections are used. After a failed parse, reset or discard the buffer before reusing it; no partial result is returned. The reader must be bounded to one message.
