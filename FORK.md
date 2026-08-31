# M5 Max hardening fork

This branch tracks [antirez/ds4](https://github.com/antirez/ds4) and adds a focused production-hardening stack for long-running local inference on an Apple M5 Max. Upstream remains the engine and model-support authority; this fork carries deployment and API edge cases that have not yet landed there.

The branch is based on upstream `main` and keeps each local change as a small, independently reviewable commit.

## What the patch stack adds

- **Abort-safe KV recovery:** interrupted requests restore a clean prompt frontier instead of leaving provisional state live.
- **Atomic disk checkpoints:** replacement snapshots commit before eviction, reserve temporary write headroom, and clean abandoned temporary files.
- **LRU retention:** the fixed disk budget favors recently used conversations.
- **OpenAI tool continuation:** structured `tool_call_id` results reconnect to GLM's sampled live frontier without replaying private tool syntax.
- **Replay-safe snapshots:** sampled evict and shutdown states cannot delete the preceding client-replayable prompt checkpoint.
- **Crossed-boundary checkpoints:** partial-cache prefills save aligned frontiers even when chunk boundaries never land on an exact interval.
- **Tool schema validation:** raw tool arguments are checked and exact decimal integers are validated without floating-point coercion.
- **Operations:** per-slot prefill/decode statistics and persisted usage metrics.

## Local deployment profile

The primary deployment is GLM 5.3 Flash Q2 running resident on a 128 GB M5 Max:

- 1,048,576-token context
- MTP decode enabled
- four batched resident sessions
- 80 GiB LRU disk KV budget
- 4,096-token continued-checkpoint interval
- OpenAI-compatible traffic through a local proxy

These settings are deployment choices, not requirements imposed on upstream.

## Verification

The branch is gated with:

```sh
make -j18 all
DS4_TEST_MODEL=/path/to/a/test-model.gguf make test
./ds4_test --server --abort-kv-contract
```

Live checks additionally exercise an OpenAI tool call, graceful restart, and disk-prefix recovery through the proxy.

## Upstream contribution plan

Generally useful fixes should move upstream one at a time with a minimal regression test. The first candidates are:

1. Save crossed aligned checkpoint frontiers after loading an off-boundary prefix.
2. Reuse OpenAI Chat live KV by echoed tool-call ID.
3. Discuss replay-checkpoint retention policy before proposing the broader pruning change.

Keeping these separate avoids presenting the full deployment stack as one large pull request and makes maintainer review practical.
