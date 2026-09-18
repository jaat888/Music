# SurSathi v88 — Build Fix + Smooth Seekbar

## Fixed

### 1. Release APK compile failure in `youtube_service.dart`
The release build failed at `lib/services/youtube_service.dart:1773:10` with:
`Error: A named parameter can't start with an underscore ('_').`

The retry flag was declared as a private named parameter:
`_retryAfterCdnFailure`

Dart does not allow `_`-prefixed named parameter declarations. It is now the public named parameter:
`retryAfterCdnFailure`

The recursive retry call was updated to use the same name. Runtime behavior is unchanged: the CDN failure path still re-resolves the stream only once and then stops retrying.

### 2. Progress/seekbar behavior retained
The v87 behavior remains in place: if the current track is already playing, a short ExoPlayer buffering blip does **not** unnecessarily disable/lock the seekbar. The seekbar only enters its loading guard when playback has not actually started.

### 3. Existing v87 smooth Radio behavior retained
- Upcoming Radio songs are URL-warmed only, not fully downloaded in the background.
- Radio owner-lock/race protection remains.
- Radio swipe navigation remains.
- Player play/pause state uses the actual player state.
- Buffered seekbar values are clamped safely.

## Validation

The reported compiler error was matched directly to the source declaration and corrected. Flutter/Dart SDK is not installed in this environment, so a local `flutter build apk --release` cannot be executed here. The project ZIP was recreated after the source fix.
