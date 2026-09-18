# SurSathi v86 — Stability Audit (2026-09-18)

This batch is based on the attached real-device log plus a source audit of the v85 project.

## Fixed

1. **Radio recovery false-failure race** — recovery now waits for `playingStream` instead of sampling `player.playing` immediately after `playWithRetry()`.
2. **Local-file playback race** — downloaded/cache playback now confirms `playing=true` before declaring the phase `playing`.
3. **Radio prefetch request storm** — Radio no longer launches five resolver/download jobs at once. Prefetch is limited to a small warm URL window and shares one serialized resolver queue.
4. **Unnecessary background full-track prefetch downloads** — upcoming tracks are warmed by URL only; the currently playing track remains the normal cache target. This reduces bandwidth and YouTube request pressure.
5. **Stale DownloadDB rows** — missing/deleted files are removed from the DB so the app can download the song again instead of incorrectly reporting it as already downloaded.
6. **Download filename collision** — different YouTube videos with the same title no longer overwrite each other; a short video-ID suffix is used when the title path is occupied.
7. **Range-download progression** — the downloader now follows the actual `Content-Range` end when available instead of blindly advancing by 10 MB, preventing skipped bytes after a short response.
8. **Range ignored by CDN** — a large `200` full-object response is rejected instead of being appended as a range chunk, preventing silent file corruption.

## Known external limitations

- YouTube can rate-limit an IP (`RequestLimitExceededException`). The app now reduces avoidable prefetch pressure, but no client-side code can guarantee that YouTube will never rate-limit an IP.
- Public Piped instances can return 502/525/403, DNS failures, or timeouts. They remain fallback sources only.
- Flutter/Dart SDK is not installed in this build environment, so `flutter analyze`, `flutter test`, and an APK build could not be executed here.
