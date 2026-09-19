# V116 — Mood Mode + iTunes daily snapshot + lyrics cache isolation

## Included

1. **Lyrics strict-cache isolation**
   - Normal LyricsScreen keeps `lyrics_v5_<songId>` cache.
   - Radio strict synced lookup now uses `lyrics_v5_synced_<songId>`.
   - A normal-screen cached first provider can no longer bypass Radio’s all-provider timed quality scan.
   - Timed lyric word joins now keep ASCII apostrophe contractions tight (`don` + `'t` -> `don't`).

2. **Mood Mode two-step flow**
   - Moods opens with the same Radio language choices first.
   - Next screen asks for Chill / Workout / Party / Sad / Focus.
   - Selecting a mood launches the hardened Radio player in strict Mood mode.
   - Mood candidates must match an explicit mood keyword in title/artist metadata.
   - Language hard gates, <=7 minute duration, 90-day exact-song history exclusion, failed-session exclusion, and <=2-year YouTube-upload freshness gates are reused from Radio.
   - Latest-month candidates are a hard first phase; broader <=2-year candidates are used only after the latest pool is exhausted.
   - Mood query seeds rotate across refills so long sessions do not depend on one deterministic first search page.
   - Playback remains continuous through the existing Radio advance/look-ahead pipeline.

3. **iTunes India Top Songs daily snapshot**
   - Home no longer re-downloads the iTunes chart every time the screen opens.
   - Cache window is anchored to local device 06:00 -> 06:00.
   - First Home load after 06:00 performs at most one refresh for that daily window.
   - Previous good snapshot is kept on network/API failure.
   - This is an on-open refresh/cache policy; Android may defer background work when the app is fully closed, so an exact 06:00 background network fetch is not claimed.

## Validation

Flutter/Dart SDK is not installed in the sandbox, so `flutter analyze`, `flutter test`, APK build, and real-device playback were not run here. Static source review and targeted test additions were performed.

Version: `1.0.0+563`
