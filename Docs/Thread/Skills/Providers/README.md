# Providers

Thread supports two embedding backends, selected at startup via `--use-mlx`. Both produce 1024-dimensional float32 vectors.

---

## Backends

### Mistral API (default)

`EmbeddingModelProvider` — actor-based API client for `mistral-embed`.

- Max 3 concurrent slots enforced via a priority queue. Requests beyond the limit wait in the queue until a slot opens.
- Identical texts within a batch are **coalesced** into one API call; the result is fanned back to all waiters.
- Requires `MISTRAL_API_KEY` in environment.
- Model: `mistral-embed`, 1024 dimensions.

**Adding concurrency**: change `maxConcurrent` in `EmbeddingModelProvider`. Each slot maps to one in-flight API request.

### On-device MLX (`--use-mlx`)

`MLXEmbeddingModelProvider` — runs entirely on Apple Silicon GPU via MLX.

- Model is fetched into Rao's models folder (`~/.rao/models/huggingface`, `AIIHome.huggingFaceHome`) on first request.
- No API key or network access needed after download.
- Default model: `AIIModels.embedding` (`rao-studios/voyage-4-nano-mlx-8bit`, at its pinned revision).
- Override with `--mlx-model <hub-model-id>`.
- Model: 1024 dimensions (must match Mistral's output dimension — PQ indices are not interchangeable between models).

**Switching models**: if you change `--mlx-model`, any existing index data was indexed under the old model's embedding space. Rebuild the index from scratch or use a separate data directory.

---

## Provider Protocol

Both backends conform to `EmbeddingProviding` (protocol defined in [EmbeddingModelProvider.swift](../../../../Sources/Thread/Providers/EmbeddingModelProvider.swift)):

```swift
protocol EmbeddingProviding: Actor {
    func run(_ texts: [String], logger: Logger, role: EmbeddingRole) async throws
        -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage)
    // plus preprocess slots, vectorSpace, health and warmup (the last three have defaults)
}
```

To add a new backend: implement the protocol and wire it into `ThreadServer.swift` as an alternative to the two existing providers.

---

## Tag Embeddings

Tags are not embedded: each is filed as a `concept` entity, which a query matches by name (see [Database](../Database/README.md)). The same provider used for document partitions also embeds relationships and predicates (role `document`) and search text (role `query`).

---

## Key Files

| File | Purpose |
|---|---|
| [EmbeddingModelProvider.swift](../../../../Sources/Thread/Providers/EmbeddingModelProvider.swift) | Protocol + Mistral actor implementation |
| [MLXEmbeddingModelProvider.swift](../../../../Sources/Thread/Providers/MLXEmbeddingModelProvider.swift) | On-device MLX implementation |
| [AppConstants.swift](../../../../Sources/Thread/Utilities/AppConstants.swift) | Default host and port, SSE framing |
