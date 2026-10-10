# Amount validation benchmarks

Have you seen this loop in [Amount.zig](../src/x402/Amount.zig)?

```zig
    for (bytes) |byte| {
        if (byte < '0' or byte > '9')
            return error.InvalidAmount;
    }
```

Have you read "[Everyone Should Know SIMD](https://mitchellh.com/writing/everyone-should-know-simd)"?

Should we use vectors and SIMD instead of this loop? Here are my two cents.

---

Run the benchmark:

```sh
zig build bench-amount -Doptimize=ReleaseFast
```

## Implementations

- `scalar_early`: the production `Amount.parse`, with early rejection.
- `scalar_full`: a prefix check followed by a complete digit scan. This lets us inspect whether the compiler automatically vectorizes a scalar reduction.
- `vector_16`: a prefix check with 16-byte vectors and early rejection per block, and a scalar tail.

Sixteen bytes is a fixed experimental width.

For USDC 4-byte `1000` amount is $0.001, 7-byte `1000000` – $1.

## Initial baseline

The baseline below uses a 100 ms calibration target and five samples.

Recorded on 2026-10-10: Zig `0.17.0`, aarch64-macos, CPU `apple_m3`, LLVM backend, `ReleaseFast`.

| Case                          | scalar early ns/op | scalar full ns/op | vector 16 ns/op |
| ----------------------------- | -----------------: | ----------------: | --------------: |
| Valid, 4 bytes                |              2.395 |             1.736 |           2.641 |
| Invalid first byte, 4 bytes   |              1.060 |             1.738 |           1.303 |
| Invalid last byte, 4 bytes    |              2.403 |             1.748 |           2.746 |
| Valid, 6 bytes                |              3.145 |             2.224 |           3.188 |
| Valid, 7 bytes                |              3.447 |             2.421 |           3.675 |
| Valid, 20 bytes               |              8.780 |             4.645 |           2.931 |
| Valid, 78 bytes               |             32.606 |            17.224 |           7.736 |
| Valid, 128 bytes              |             60.621 |            27.949 |           4.010 |
| Invalid first byte, 128 bytes |              1.068 |            27.931 |           1.065 |
| Mixed valid lengths           |             13.484 |             7.460 |           3.484 |
