# V107 — 2026-09-19 — Deep bug-fix pass by ChatGPT (OpenAI)

**User request:** v106 ke deep audit me jo playback/Radio/search/queue bugs mile the, unko fix karo aur exact reason + change record karo.

**Important validation note:** is environment me Flutter/Dart SDK available nahi tha, isliye `flutter analyze`, `flutter test`, APK build aur real-device playback test **run nahi ho sake**. V107 ko source-level review, diff checks aur cross-file race tracing se patch kiya gaya. Real device par final verification abhi bhi zaroori hai.

## 17 fixes applied

1. **Native `setUrl`/`setAudioSource` stale prepare race — FIXED.**
   - **V106 problem:** `Future.timeout()` Dart ka wait timeout karta tha, lekin underlying just_audio/ExoPlayer prepare operation cancel nahi hota tha.
   - **Why it happened:** naya retry same shared `AudioPlayer` par start ho raha tha jab purana native prepare abhi background me zinda tha.
   - **V107 change:** active prepare Future track kiya, replacement se pehle `player.stop()` + short unwind wait kiya, aur source-generation guard rakha. Local `setFilePath()` path bhi isi protection me aa gaya.

2. **`stop()` ke baad stale source recovery — FIXED.**
   - **V106 problem:** explicit stop ke baad late native/error signal current playback context me recovery trigger kar sakta tha.
   - **Why:** stop user intent tha, lekin in-flight source operation invalidate/cancel nahi hota tha.
   - **V107 change:** stop ab play/source generations invalidate karta hai, active prepare abort karta hai, watchdog disarm karta hai aur `_userPaused` intent preserve karta hai.

3. **Silent mid-play freeze watchdog — FIXED/strengthened.**
   - **V106 problem:** watchdog mainly `ProcessingState.buffering` par dependent tha; silent `ready + position not advancing` freeze miss ho sakta tha.
   - **Why:** network/CDN kabhi exception ya buffering state diye bina frozen playback leave kar sakta hai.
   - **V107 change:** confirmed playback ke baad watchdog position advance track karta hai; READY ya BUFFERING dono me 8s tak no-progress par existing stream-drop recovery trigger hoti hai. Timer source-event spam se reset nahi hota.

4. **Radio stale `completed` event — FIXED.**
   - **V106 problem:** Radio screen apna `completed` listener current candidate ki confirmed completion identity ke bina auto-advance kar sakta tha.
   - **Why:** shared player stream par stale native completion event aur current Radio candidate alag timelines the.
   - **V107 change:** current candidate playback-start timestamp + near-end position validation ke bina completion ignore hoti hai; naya candidate start hote hi old completion context invalidate ho jata hai.

5. **Radio candidate fetch stale session race — FIXED.**
   - **V106 problem:** `_fetchCandidates()` direct `_candidates` mutate karta tha while async searches chal rahe the.
   - **Why:** old Radio session ka slow search new session ke state me return kar sakta tha.
   - **V107 change:** local candidate staging + fetch generation + session generation; commit sirf latest session ko hota hai.

6. **Radio recovery same-song stale Future reuse — FIXED.**
   - **V106 problem:** recovery lock sirf `songId` se identify hota tha.
   - **Why:** same song later/new candidate generation me aaye to old recovery Future reuse ho sakta tha.
   - **V107 change:** recovery key me candidate generation add kiya gaya.

7. **Radio Previous single-attempt failure — FIXED.**
   - **V106 problem:** Previous sirf ek old candidate try karta tha; fail hone par ruk jata tha.
   - **Why:** previous path me Next jaisa bounded fallback loop nahi tha.
   - **V107 change:** Previous ab up to 12 prior candidates fallback me try karta hai; failed entries mark/remove hoti hain.

8. **QueueService stale Radio refill append — FIXED.**
   - **V106 problem:** in-flight refill old queue mode/supplier ke results baad me active queue me append kar sakta tha.
   - **Why:** supplier Future ke completion par queue state revalidated nahi hoti thi.
   - **V107 change:** Radio generation + supplier identity check + duplicate song-ID filtering before append.

9. **Search continuation singleton contamination — FIXED.**
   - **V106 problem:** `_moreSearchQuery`, continuation aur exhausted state global singleton fields the.
   - **Why:** app me multiple async queries/search screens/categories ek hi mutable pagination state share kar rahe the.
   - **V107 change:** per-query `_SearchPaginationState` map + generation.

10. **Radio continuation singleton contamination — FIXED.**
    - **V106 problem:** radio seed/continuation/exhausted ek hi global state me the.
    - **Why:** alag radio seeds/DailyMix calls ek doosre ka continuation overwrite kar sakte the.
    - **V107 change:** per-seed `_RadioPaginationState` map; no-arg load-more latest seed use karta hai, explicit seed bhi accepted hai.

11. **Audio focus service not wired at startup — FIXED.**
    - **V106 problem:** `AudioFocusService` implementation thi, par app startup se configure call missing tha.
    - **Why:** service code hone ke baad actual audio-session initialization nahi hui.
    - **V107 change:** `main.dart` startup me configure kiya; interruption pause, duck/restore volume aur headphone-unplug pause wired hain.

12. **Favorite boost repeated like/unlike se drift — FIXED.**
    - **V106 problem:** every like `+10` add karta tha, unlike reverse nahi karta tha.
    - **Why:** favorite boost ko reversible operation ke bajay one-way score mutation treat kiya gaya.
    - **V107 change:** per-tag favorite boost counts + `removeFavorite()`; unlike sirf apna ek active boost reverse karta hai.

13. **Radio artwork/metadata stale preload work — FIXED.**
    - **V106 problem:** slow artwork/metadata preloads old Radio candidate ke liye continue kar sakte the.
    - **Why:** candidate generation sirf lyrics prefetch me guard thi; artwork loop me nahi.
    - **V107 change:** preload pass generation snapshot, per-item cancellation check aur final prefetch guard.

14. **Radio progress ticker raw `player.playing` — FIXED.**
    - **V106 problem:** button effective playback signal use karta tha, progress ticker raw `playing`.
    - **Why:** playback-state sources unify nahi the; hand-off gap me progress temporarily ruk sakti thi.
    - **V107 change:** `RadioPlayerProgress` optional effective-playing callback use karta hai, wired to `audioHandler.effectivelyPlaying`.

15. **Native NewPipe unbounded executor — FIXED.**
    - **V106 problem:** `newCachedThreadPool()` stale/retry bursts ke saath unlimited workers create kar sakta tha.
    - **Why:** each resolver request ko bounded concurrency ke bina submit kiya ja raha tha.
    - **V107 change:** native executor `newFixedThreadPool(2)` kiya gaya, taaki concurrency bounded rahe while one worker slow ho to doosra foreground request ko chance de.

16. **Search Load More fallback page-1 duplicate risk — FIXED.**
    - **V106 problem:** InnerTube continuation missing/fail hone par `youtube_explode_dart` generic search ko “Load More” ki tarah call kiya ja raha tha, jo page-1 data dubara la sakta tha.
    - **Why:** initial fallback aur true continuation pagination ko same API path maan liya gaya.
    - **V107 change:** relevance Load More ab sirf tracked InnerTube continuation use karta hai; compatible continuation nahi to exhausted/empty return hota hai, page-1 fallback nahi.

17. **Theme toggle Navigation reset — FIXED.**
    - **V106 problem:** `MaterialApp(key: ValueKey(isLight))` theme change par entire MaterialApp/Navigator identity reset karta tha.
    - **Why:** instant theme refresh ke liye whole MaterialApp ko keyed recreation diya gaya tha.
    - **V107 change:** key remove; ThemeData rebuild hota hai lekin Navigator stack preserve hota hai.

## V106 ka already-existing fix jo preserve kiya gaya

`playbackEventStream` stale-error ke liye v106 ka 1.8s source-switch settle logic retain kiya gaya. Is pass me use blanketly “remove” nahi kiya gaya, kyunki ye current-source async error aur old-source delayed error ke beech ek practical guard hai. Final runtime verification zaroori hai.

## Items intentionally NOT changed in V107

- Production release keystore/signing configuration.
- `MANAGE_EXTERNAL_STORAGE` Play policy/product decision.
- Play-history “listened seconds = full track duration” semantics.
- Missing Gradle wrapper/project packaging files.
- Dual Radio architectures (dedicated Radio Player vs QueueService radio mode) — ye larger architecture decision hai, automatic bug patch nahi.
- Full AudioHandler `dispose()` lifecycle refactor — risky without runtime/build validation.

## Version

`pubspec.yaml`: `1.0.0+553` → `1.0.0+554`.

## V107 source files changed

- `lib/services/background_service.dart`
- `lib/screens/radio_player_screen.dart`
- `lib/services/queue_service.dart`
- `lib/services/youtube_service.dart`
- `lib/services/radio_service.dart`
- `lib/main.dart`
- `android/app/src/main/kotlin/com/sursathi/sursathi/newpipe/NewPipeAudioChannel.kt`
- `pubspec.yaml`

