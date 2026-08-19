# Performance Measurement

Own AI has three complementary measurement layers:

1. `OSLog` entries in the `Performance` category for live inspection.
2. Points of Interest signposts for interval analysis in Instruments.
3. A bounded on-device history shown at **Settings → Performance**.

No prompt, response, document text, or file name is stored in performance
history. Measurements contain durations, counts, model identifiers, engine
types, status, and resident-memory values.

## Metrics

| Metric | Begins | Ends | Initial target |
| --- | --- | --- | ---: |
| App launch | Before app managers initialize | First content appearance | 1,000 ms |
| Model load | Cold model load starts | Model is ready or fails | 3,000 ms |
| First token | Generation starts | First non-empty streamed update | 1,000 ms |
| Chat response | User response task starts | Message finalization | Informational |
| Generation | Engine generation starts | Engine completes or fails | Informational |
| Document extraction | File processing starts | Extracted document is ready | 3,000 ms |
| Document indexing | RAG ingestion starts | Chunks and embeddings are ready | 3,000 ms |

Total generation and chat-response durations are informational because they
depend on the requested output length. Compare first-token latency and effective
tokens per second when investigating model responsiveness.

The dashboard reports median, p95, latest value, recent trend, failure count,
peak recorded memory, and per-model first-token/generation statistics. Target
ratings use p95 rather than the latest sample so one unusually slow operation
does not immediately classify a path as regressed.

## Storage

- History is stored under Application Support in `PerformanceMetrics`.
- Samples older than 30 days are removed.
- At most 1,000 samples are retained.
- Writes are debounced and run through an actor away from the main UI.
- Collection can be paused and existing history can be cleared in the dashboard.

## Console

Use this filter in Console:

```text
subsystem:alice.turcanu.LocalAI category:Performance
```

Detailed sequencing messages use the `Diagnostics` category and are private
masked by default.

## Instruments

Profile a physical device build and add the **Points of Interest** track. Repeat
the same interaction at least five times, excluding the first run when comparing
warm behavior. For launch analysis, terminate the app between captures.

## Comparing Changes

1. Export a JSON report before making a performance change.
2. Repeat the same device, model, prompt shape, document, and power conditions.
3. Collect at least five new samples per path.
4. Compare median for typical behavior and p95 for worst-case behavior.
5. Confirm the improvement in Instruments before removing or restructuring hot code.
