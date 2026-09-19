## V114 (2026-09-19) — Radio freshness + strict language + duration gates

### Requested Radio rules

1. Same-song repeat window: **150 days → 90 days**.
2. Radio search pool: **no candidate above 7:00**. Unknown duration is rejected too, so a track cannot bypass the cap just because search metadata is missing.
3. Very old Radio material is capped by a **2-year YouTube upload-date window**. The latest bucket remains a stricter last-month query.
4. Language selection is tightened: query-level negative terms plus metadata guards reject obvious cross-language leakage. Example: Haryanvi selection rejects Gurmukhi/Punjabi-labelled results.
5. Old/new balance is still not a fixed percentage. Recency and latest signals were strengthened slightly so 1–2 year-old eligible material is less likely than fresher material.

### Important date limitation

The app does not store a song's original commercial release date. The 2-year hard gate therefore uses **YouTube upload date**, not the original song release year. A 2018 song re-uploaded in 2025 can pass the upload-date gate; a 2025 song whose YouTube upload is older than two years would not.

### Why this is stricter than the earlier Radio logic

Earlier Radio treated language mainly as the query label: a result returned by a Haryanvi query was simply tagged `language: haryanvi`. That allowed YouTube search contamination (for example Punjabi results returned for a Haryanvi query). V114 adds query exclusions and a second metadata gate before the candidate can enter the engine.

### Persisted old-song resume guard

V114 also removes the old persisted-`last Radio song` startup shortcut. That stored record had no authoritative YouTube upload date, so it could bypass the new 2-year freshness gate. Radio now starts from the freshly filtered candidate pool every session.

### Pagination fix included

The old Radio continuation path used `searchPage()` without the active date filter. That meant a date-filtered first page could be followed by an unfiltered InnerTube continuation. V114 adds date-aware `searchPage(..., dateFilter: ...)` for Radio, so the two-year/month boundary remains active across the extra pages.

### Validation

Added pure unit tests for the 7-minute hard gate and obvious Haryanvi/Punjabi leakage. Flutter/Android runtime playback was not executed in this environment because the Flutter SDK/device runtime is unavailable here.
