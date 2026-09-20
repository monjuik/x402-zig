# x402-zig

An x402 v2 core library with predictable latency and bounded memory use.


## Why I am building this

I believe that resource-efficient software has additional value. This library helps deploying x402 components close to the target services.
It could be used by infrastructure providers such as Cloudflare to offer x402-based payment capabilities to the customers.

## Memory use

The library is designed for bound memory use, without hidden allocations. Applications are able to reserve all needed memory during startup.
