# SurSathi v92 — real playback latch fix

The device log showed the player reaching `playing=true` and then being treated as failed during a later transient stream/resolve event. The UI also used transition/loading flags that could outlive the real audio start.

Changes:
- Added a per-play-token playback-start latch. Once a current request is genuinely started, a brief `playing=false` publication during READY/BUFFERING does not turn it into a failed candidate or fake Play spinner.
- Start confirmation accepts the authoritative `player.playing` signal and, as fallback, actual position advance while READY.
- Radio Play/Pause now also listens to position and the playback latch. If audio is actually running, Pause is immediate even when `_loading`/`_transitioning` is stale.
- Full-player seekbar uses the same started signal so a short buffering publication does not lock it.
- Radio URL warm-up is limited to the immediate next song to reduce YouTube extraction/rate-limit pressure while retaining warm-next behavior. No full upcoming-song downloads are started.
