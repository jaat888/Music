## V115 — 2026-09-19 — Radio lyrics strict timing scan + word-spacing fix

### User-reported Radio lyrics problems

1. Kuch songs me lyrics source milta tha, lekin **time-synced lyrics** available hain ya nahi ye Radio strictly verify nahi karta tha. Plain lyrics aane par Radio unhe bhi display kar sakta tha.
2. Multiple lyric providers me synced versions ho sakte hain, lekin old flow **first synced response par return** kar deta tha; isliye kisi doosre provider ki zyada complete timing ko compare nahi kiya jaata tha.
3. BetterLyrics TTML me `<span>` text ko direct concatenate kiya ja raha tha. Jab provider word spans ke beech whitespace nahi deta tha, result `meradilyeh` jaisa mix ho sakta tha.

### Fix

- Radio ke liye naya strict `getSyncedForSong()` path add kiya.
- Timing-capable providers ko scan kiya jaata hai: BetterLyrics, LRCLIB exact, LRCLIB search, Kugou.
- Saare returned timed results ko compare karke **timeline coverage + line completeness** ke basis par source select hota hai.
- Radio ko plain-only lyrics intentionally nahi diye jaate. Koi usable timed lyrics nahi mile to UI seedha **"Lyrics not available for this song"** dikhata hai.
- Radio look-ahead prefetch bhi strict synced path use karta hai, isliye future songs ke plain lyrics bandwidth waste karke timed lookup ko mask nahi karte.
- TTML timed word spans ke beech automatic whitespace normalization add ki gayi; punctuation ke pehle unnecessary space nahi dala jaata.
- LRC/plain/cached lyric text me whitespace normalization add ki gayi, taaki old cached malformed spacing dobara mix na ho.

### Important behavior

Radio abhi bhi normal Lyrics screen se alag strict hai: normal Lyrics screen plain fallback dikha sakti hai, lekin Radio me bina timestamps ke lyrics nahi dikhengi.

### Validation

- Added unit tests for timed-word spacing, punctuation spacing aur timing coverage scoring.
- Flutter SDK/device runtime is environment me available nahi tha, isliye `flutter test`, `flutter analyze`, APK build aur real-device playback validation run nahi ki gayi.

### Version

`1.0.0+561` → `1.0.0+562`
