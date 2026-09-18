# SurSathi v90 — Playback-start signal / fake spinner fix

## What the device log + source logic showed

A Radio transition could briefly publish `playing=false` while the new source was already READY and its position was advancing. Radio UI used the raw boolean for its spinner, while the playback layer waited only for `playing=true` before declaring a candidate started. That made a smoothly audible song look like Buffering and could make Radio treat a valid start as a failed candidate.

## Fix

- Added `playbackStarted` as an effective playback signal: real `player.playing` OR the committed `PlaybackPhase.playing` while the player is READY and the user has not paused.
- `_waitUntilPlaying()` now confirms playback using either `playing=true` OR real position advancement while the player is READY.
- Radio Play/Pause uses the effective started signal so a tiny ExoPlayer publication gap does not show a spinner over a smoothly playing song.
- Notification playback state uses the same effective signal, keeping controls consistent during the brief gap.
- Existing URL warm-up, Radio race protection, and seekbar behavior are retained.

Flutter SDK is not installed in this environment, so a local `flutter analyze` / release APK build cannot be executed here.
