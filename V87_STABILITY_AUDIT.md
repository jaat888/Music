# SurSathi v87 — Playback Smoothness Pass

- Retained v86 serialized Radio warm-URL prefetch. Upcoming tracks are still URL-warmed only; no full background downloads.
- Full player center Play/Pause now trusts actual just_audio `player.playing` when deciding whether a transient buffering state should show a spinner. This prevents the 1-second Play/Pause flicker while audio is already audible.
- Full player seekbar remains interactive during transient buffering when the current track is already playing; it is locked only before playback has actually started.
- Progress slider clamps buffered position to the valid 0..duration range so malformed/transient player values cannot distort the slider.
- Existing Radio owner-lock, swipe navigation, playback-start confirmation, download retry/range handling, and v86 request-throttling changes remain included.

Note: Flutter/Dart SDK was not available in the editing environment, so a local `flutter analyze`/APK build could not be run here.
