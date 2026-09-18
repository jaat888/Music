# SurSathi v89 — Radio race / control fix

- Fixed a startup race where the initial Radio `_start()` loop could continue after the user changed songs, then hijack playback with attempts 2–12. Radio navigation now invalidates the startup generation and `_start()` exits immediately when superseded.
- Fixed Radio URL warming using the wrong queue: Radio has its own `_upcoming` list while QueueService is empty during Radio ownership. The next two Radio songs are now URL-warmed after the current song commits successfully. No full upcoming-song downloads are started.
- Fixed the Radio Play/Pause control showing a spinner while audio is already playing. The actual `just_audio` playing state now wins over transient loading/buffering bookkeeping.
- Fixed seekbar interactivity during an already-playing buffering blip: a playing player with a known duration remains seekable.
- Pending Previous/Next commands are drained on a microtask after `_transitioning` is cleared, avoiding the old same-frame race.
