# SurSathi — Notes / Known Issues

## Post-v75 Batch (2026-09-18) — Caching consolidation + subtitle-listener fix + first tests

User ne poochha tha "caching 3 alag paths me hai, overlap/conflict ka
risk" aur "koi automated test nahi hai" — dono confirm hue, aur teeno
fix kiye:

1. **Caching consolidation:** `DownloadDB.getFilePath(id) ??
   CacheDB.getFilePath(id)` priority-check pehle **7 alag jagah**
   copy-paste tha (background_service.dart x3, recently_played_screen,
   mood_playlist_screen, smart_playlist_screen). Naya
   `lib/services/local_media_resolver.dart` (`LocalMediaResolver`) ab
   single source-of-truth hai — sab 5 jagah (`duplicate_songs_screen.dart`
   jaanbujhke chhoda, wo independent delete-both logic hai) ab isi ko
   call karte hain. Koi behavior change nahi, sirf ek jagah consolidate.
2. **Real race condition mili aur fix hui:** `_autoCacheInBackground()`
   2+ jagah se (prefetch + actual play) SAME song ke liye overlap ho
   sakta tha — dono `file.exists()==false` dekh ke ek saath download+write
   shuru kar dete, ek hi file pe do parallel writes se corruption ho
   sakta tha. Fix: per-songId in-flight `Future` registry — dusra caller
   pehle wale ka hi Future await karta hai, naya download nahi shuru
   karta.
3. **Subtitle bug (chhota, saath me mila):** `mini_player.dart` +
   `full_player_screen.dart` sirf `audioHandler.phase`
   (`ValueListenableBuilder<PlaybackPhase>`) pe listen karte the,
   `phaseMessage` pe nahi. Retry-loops SAME phase (`retrying`) ko naya
   message ("Try 1/3..." → "Try 2/3...") ke saath repeat karte hain —
   `ValueNotifier` same-enum-value pe notify nahi karta, isliye text
   pehle attempt ke message pe frozen reh jaata tha. Fix: dono widgets ab
   `AnimatedBuilder` + `Listenable.merge([phase, phaseMessage])` use
   karte hain.
4. **`pause()` ka symmetric gap fix kiya** — dekho play()/stop() ka
   comment neeche same file me; `pause()` ka guard bhi pehle sirf
   `playing→paused` handle karta tha, ab kisi bhi frozen phase se
   `paused` pe reset ho jaata hai.
5. **Pehla test likha:** `test/local_media_resolver_test.dart` —
   `LocalMediaResolver` ki Download>Cache priority logic test karta hai
   (fake lookup-functions se, koi real DB/mocking-package nahi chahiye).
   `flutter test` se chalta hai. **Poore codebase ka pehla aur abhi tak
   ka EKLAUTA test hai** — playback state-machine (`phase`/`_playToken`)
   jaisi cheezein abhi bhi untested hain, unke liye just_audio/
   audio_service ka proper mocking harness chahiye hoga (bada, alag
   task) — abhi scope me nahi kiya, bataya hai taaki pata rahe.

> ⚠️ **PADHO ISSE PEHLE KUCH BHI CHHEDNE SE (naya Claude instance bhi):**
> 1. **Streaming/resolve pipeline** (`youtube_service.dart`, `innertube_client.dart`,
>    `background_service.dart` ke `_resolveAndPlay`/`playSong`/CDN headers wale
>    hisse, NewPipe native code) — isme **koi chhed-chhaad na karo** jab tak
>    user specifically isi cheez ka bug na bataye. Ye sabse fragile, sabse
>    zyada round-trip liya hua hissa hai — chhoti si "cleanup" bhi purana
>    fixed bug wapas la sakti hai.
> 2. **Notification icon crash** (`Invalid notification (no valid small icon)`,
>    channel `com.sursathi.audio`) — ye bug **kai baar recur ho chuka hai**.
>    Fix already laga hua hai: `androidNotificationIcon: 'drawable/ic_notification'`
>    (background_service.dart) + drawable khud
>    (`android/app/src/main/res/drawable/ic_notification.xml`) + resource
>    shrinker se protect karne wala `android/app/src/main/res/raw/keep.xml`
>    (`tools:keep`) + `build.gradle` me `minifyEnabled false, shrinkResources
>    false` explicitly set. **In teeno files ko touch mat karo, aur inhe kabhi
>    delete/revert mat karo** — warna ye bug FIR SE aayega.

> 3. **CDN headers aur download icon states** (Batch 24 se) — download/radio/
>    sleep-timer icon ab actual state (on/off) reflect karte hain. Inhe wapas
>    static grey icon mat banao — user ne specifically iski request ki thi.

## Post-v75 Fix (2026-09-18) — "Buffering..." hamesha ke liye stuck (real-device log, v71 se ALAG bug)

User ne 2 screenshot + poora app log bheja: audio bilkul sahi baj raha tha
(pause-icon, position badh rahi thi) lekin subtitle text hamesha "Buffering..."
pe atka reh gaya — v71 fix (`playFromFile()`) laga hone ke baad bhi. Root
cause alag nikla, is baar streaming (network) path me.

**Root cause:** `phase` sirf `_playSong()` (buffering→playing) aur `play()`
control (`paused→playing`) se set hota tha. `stop()` (background_service.dart)
`phase` ko **kabhi touch hi nahi karta tha** — sirf `player.stop()` +
`_playToken` bump karta tha. Log se confirm hua: Radio screen se bahar aane
pe (`dispose()` → `setRadioPlaybackOwned(false)` + `stop()`) `stop()` theek
us waqt aaya jab ek naya gaana `buffering` phase me tha. `_playToken` bump
hone se us gaane ka pending `_setPhase(playing)` call stale-token guard se
silently drop ho gaya — `phase` `buffering` pe FROZEN reh gaya. User ne
dobara Play dabaya (full player se, resume — naya resolve nahi), lekin
purana `play()` guard sirf `paused→playing` handle karta tha, `buffering`
wali stuck state ko nahi — isliye text hamesha atka raha, chahe audio
genuinely `playing=true, ready` ho.

**Fix (`background_service.dart`):**
1. `stop()` ab `player.stop()` ke baad explicit `_setPhase(_playToken,
   PlaybackPhase.idle)` karta hai — ab kabhi bhi resolve-ke-beech `phase`
   frozen nahi rahega, `stop()` definitive reset karta hai.
2. `play()` ka guard `paused`-only se broaden karke unconditional kar diya
   — jab bhi `player.play()` genuinely successful ho aur `phase` already
   `playing` na ho, use `playing` set kar do. Isse koi bhi frozen state
   (buffering/resolving/retrying/error/idle) resume pe hamesha clear ho
   jaati hai, chahe wo kaise bhi aayi ho.

**In dono methods (`play()`/`stop()`) ko is fix ke alawa touch mat karo** —
poore file ka streaming-adjacent hissa hai (dekho upar ka warning #1).

**Bonus (fix NAHI kiya, sirf note kiya):** log ke aakhir me ek video-ID ke
liye sainkdo concurrent resolve-requests (YT explode + saare Piped mirrors
+ NewPipe) ek saath fire ho rahe the — YT rate-limit (429) aur Piped
mirrors ka down hona isi wajah se aur bura ho raha lagta hai. Ye alag
issue hai (dedup missing lagta hai resolve pipeline me) — user se confirm
kiye bina isse touch nahi kiya (upar ka warning #1 wahi kehta hai).

## Post-v69 Addition (2026-09-18) — Detailed logging (buttons, notification, Radio)

User ne demand ki: log me sirf "YT PLAY OK/FAIL" jaisi high-level lines ke
alawa ye bhi chahiye — kaunsa button (play/pause/seek/stop/skip/shuffle/
repeat) kab dabaya gaya aur uska response kya raha, notification kis
state me kab/kaise dikh rahi thi, aur Radio mode ka poora flow (start/
advance/previous/error-recovery) alag se saaf-saaf trace ho sake — kyunki
abhi tak in sab ke liye koi log hi nahi tha, isliye bug reproduce karna
mushkil ho raha tha.

**Kya add hua:**
1. `background_service.dart` — `_logCtl()` helper: `play()`, `pause()`,
   `seek()`, `stop()`, `skipToNext()`, `skipToPrevious()`,
   `setShuffleMode()`, `setRepeatMode()` — sab `[CTL]` tag ke saath
   "called"/"DONE" log karte hain, saath me us waqt ka playing/
   processingState/phase bhi. **Important:** audio_service ye methods
   full-player/mini-player UI KE BUTTONS aur notification/lock-screen KE
   CONTROLS — dono jagah se EK hi shared handler ke through call karta
   hai, isliye ye ek jagah ka instrumentation dono cover karta hai (alag
   se har UI widget me lagane ki zaroorat nahi thi).
2. `_broadcastState()` — pehle kuch log nahi tha (aur har playback-event
   pe fire hota hai, isliye har baar log karna file flood kar deta) — ab
   sirf jab `playing` ya `processingState` actually BADALTA hai, tab
   `[NOTIF]` tag se poori state (controls/compactIndices/position) log
   hoti hai — ab "notification kaise/kab badli" poori trace me dikhta hai.
3. `setRadioPlaybackOwned()` / `prefetchRadioSongs()` (background_service.dart)
   aur `radio_player_screen.dart` (`_start`, `_fetchCandidates` ka flow,
   `_advance`, `_previous`, `_togglePlay`, `_onRadioPlaybackError`,
   `_ensureRecovery` ka retry-loop) — sab `[RADIO]` tag se, har step
   ("called", "attempt N/M", "TASK COMPLETE", "FAILED") explicit log hote
   hain. Pehle is 1368-line file me EK bhi log line nahi thi.

**Grep tips (naya log file dekhte waqt):** `[CTL]` = button/control taps,
`[NOTIF]` = notification state changes, `[RADIO]` = Radio mode ka poora
flow. Baaki purane `YT PLAY/DOWNLOAD/...` prefixed lines waise hi hain.

**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v14`.

## Post-v70 Fix (2026-09-18) — Log me millisecond-difference add kiya

User ne bola time samajhna mushkil hai — do log lines ke beech kitna gap
tha ye manually calculate karna padta tha. `app_logger.dart` ka `log()`
ab har line ke saath pichli line se guzra hua time bhi likhta hai:
`[2026-09-18T...][+123ms][INFO] message` — ab kisi bhi do steps ke beech
ka exact gap ek nazar me dikh jaata hai (line se pehli hi line hamesha
`+0ms` hoti hai).

**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v15`.

## Post-v71 Fix (2026-09-18) — Screenshot: "Buffering..." stuck + [ART] log

User ne screenshot bheja: "White Brown Black" ka Pause icon dikha raha tha
(matlab ASAL me bilkul theek chal raha tha), lekin subtitle "Buffering..."
pe atka hua tha, aur neeche ek DUSRE gaane ("Galat Baat Hai") ka purana
error toast bhi dikh raha tha — matlab UI ke do hisse (play/pause icon vs
status text) sync me nahi the.

**Root cause (`playFromFile()`, downloaded/cached songs ke liye):** ye
function `player.play()` call karta tha (jo turant play/pause ICON sahi
kar deta hai, kyunki wo seedha `_broadcastState()`/`playbackState` se
aata hai) — lekin `phase` (alag ValueNotifier jo subtitle TEXT drive karta
hai) ko kabhi `PlaybackPhase.playing` set hi nahi karta tha. Isliye agar
`phase` pehle se kisi PURANE (dusre) gaane ke fail/buffering attempt se
stuck tha, aur user ek DOWNLOADED gaana tap karta (playFromFile() path —
Downloads/Library/Recently Played/Mood/Smart Playlist, sab yahi function
use karte hain) — audio turant sahi bajta, lekin text hamesha ke liye
purani stuck state dikhata rehta, jab tak koi aur unrelated phase-change
na ho.

**Fix:** `playFromFile()` me bhi doosre play-methods jaisa hi explicit
`_setPhase()` lagaya — shuru me buffering, success pe playing, fail pe
error. Ab `phase` kabhi bhi stale nahi rahega chahe playback kisi bhi
source (stream/local-file) se aaya ho.

**Bonus (user ne ye bhi maanga — "agle gaane ki photo kaisi/kitni load
hui, minimum detail"):** `_toMediaItem()` ab har naye song-change pe
`[ART]` tag se log karta hai ki us gaane ka thumb URL kya tha (ya missing
tha) — audio_service ka asli artwork-download native-side hota hai isliye
uska progress track nahi ho sakta, ye sirf itna confirm karta hai ki
sahi/khaali thumb bheja gaya tha ya nahi.

**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v16`.

## Post-v68 Fix (2026-09-18) — CHUNKED playback 100% fail (galat MIME-type guess)

User ne fresh `sursathi_app_log.txt` bheja (v68 build). Pattern bilkul saaf
tha: **HAR EK** `"CHUNKED (speed-fix)"` wala attempt turant (~100-300ms
mein) `PlatformException(0, Source error, {index: 0}, null)` deta tha;
usi gaane ka agla retry (bina CHUNKED tag ke, plain `setUrl()`) kuch der
baad theek chal jaata tha. Matlab bug specifically chunked path me tha,
random CDN-drop nahi.

**Root cause (`chunked_audio_source.dart`):** HTTP Range (206 partial)
response me `Content-Type` header googlevideo hamesha nahi bhejta. Jab
missing hota, code `_contentType` (agar pehle mila ho) ya hardcoded
`'audio/mp4'` pe fallback karta tha. Is app me resolve hone wala format
LAGBHAG HAMESHA "webm" hota hai (log confirm karta hai) — matlab fallback
ka guess (`audio/mp4`) practically hamesha GALAT hota tha. just_audio/
ExoPlayer ko explicit (galat) MIME diya jaaye to wo content-sniffing skip
karke seedha usi type ka extractor force karta hai — Mp4Extractor ko
WEBM/EBML bytes diye jaayein to wo turant fail hota hai. Non-chunked
`setUrl()` isse isliye bachta tha kyunki wahan koi forced MIME nahi diya
jaata (ExoPlayer khud sniff karta hai).

**Fix:**
1. `youtube_service.dart`: naya `getAudioUrlAndFormat()` — URL ke saath
   resolve-time-known asli format ("webm"/"mp4"/"m4a") bhi return karta hai
   (pehle `getAudioUrl()` sirf URL deta tha, format discard ho jaata tha).
   `getAudioUrl()` ab isi ka thin wrapper hai (backward-compat, jahan
   format ki zaroorat nahi — jaise debug_screen.dart, `_retryAfterStreamDrop`
   jo hamesha non-chunked hi rehta hai).
2. `background_service.dart`: `_urlCache` (prefetch cache) ab
   `{url, format}` record store karta hai; `playSong()`/`_playSong()`/
   `playWithRetry()` ke poore chain me format thread kiya gaya — jahan
   bhi `useChunking: true` hai, wahan format bhi resolve-time se seedha
   `ChunkedYoutubeAudioSource` tak jaata hai.
3. `chunked_audio_source.dart`: naya `expectedFormat` param — `_mimeForFormat()`
   ise definitive MIME me convert karke **priority #1** banata hai (HTTP
   header/hardcoded-guess ab sirf format na milne par hi last-resort
   fallback).

**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v13`.
**Test on real device:** kai alag-alag gaane chalao, Debug screen ka naya
app-log ("Load + Share" jaisa) se confirm karo ki "CHUNKED (speed-fix)"
attempts ab bhi "Source error" nahi de rahe.

 (2026-09-17) — Batch 29 ke 2 fixes properly redo (user ne reject kiya)

User ne Batch 29 ke 2 changes pe feedback diya ki wo galat approach the:

1. **Daily Mix refresh cadence** — sirf "khaali result cache mat karo"
   kaafi nahi tha; user chahte hain personalization **har 4 ghante**
   khud-ba-khud refresh ho (jaisa listening pattern din mein badalta
   rehta hai), poore CALENDAR DIN ke liye nahi. **Fix:** cache key ab
   date + "4-hour bucket" (`_periodKey`, `daily_mix_service.dart`) hai —
   din mein 6 baar (00-04, 04-08, ... 20-24) khud naya Mix generate hota
   hai, latest history ke saath.

2. **Home feed "aur gaane" section** — Batch 29 ka fix ("12 categories
   dikhne ke baad scroll ruk jao") user ko pasand nahi aaya: "YouTube se
   AUR playlist fetch karne the, tune pura hi badal diya, ab sirf repeat
   hi aayega" — matlab woh chahte the genuinely NAYA content aata rahe,
   bas rukna nahi chahiye THA (jo purana behavior "12 ke baad wapas
   Bollywood se same 12 gaane" karta tha, wahi asli buggy repeat tha,
   sirf "band kar dena" uska sahi fix nahi tha).

   **Asli sahi fix:** `youtube_service.dart` me naya `searchPage(query,
   continuation)` method (stateless, per-caller apna continuation token
   sambhalta hai — `loadMoreSearchResults()` jaisa hi mechanism jo Search
   screen already use karta hai, bas usse independent state, taaki 12
   alag categories ek-dusre ka pagination overwrite na karein).
   `home_screen.dart` ab har category ka apna `continuation` token yaad
   rakhta hai (`_categoryContinuation` map) — jab category cycle karke
   wapas aati hai, YouTube se us category ka **agla page** (naye 12
   gaane) aata hai, purane 12 nahi. Category sirf tab permanently skip
   hoti hai jab YouTube khud bole "is query ke liye aur results nahi"
   (`continuation == null`) — `_categoryExhausted` set. Jab tak kam se
   kam ek category ke paas aur pages hain, scroll kabhi dead-end nahi
   hoga, aur koi bhi do consecutive pages same nahi honge.

## Batch 29 (2026-09-17) — Daily Mix stuck-empty bug, home-feed infinite repeat, auto-download race condition

**Ask (3 alag reports):**
1. Daily Mix — shuru mein (history khaali thi) ek baar khaali aaya, uske
   baad history ban jaane ke baad bhi khaali hi dikhta raha.
2. Home screen ke neeche wala "X — aur gaane" section Search screen jaisa
   hi content dikhata hai aur baar-baar (repeat) aata hai scroll karte waqt.
3. "Auto-download on Play" setting cache ka fayda nahi utha rahi — har
   baar poora fresh network download kar deti hai, jabki gaana usi waqt
   cache bhi ho raha hota hai.

**Fixes:**

- **`daily_mix_service.dart`** — 2 jagah bug tha:
  - `_generate()` se khaali result (`[]`, jab history hi nahi thi) memory
    AUR SharedPreferences dono me `today` ki date ke saath cache ho jaata
    tha. Cache sirf DATE badalne pe invalidate hota tha, history badalne
    pe nahi — isliye "history ban gayi lekin abhi bhi khaali dikh raha"
    exactly isi wajah se ho raha tha. **Fix:** khaali result ab kahin bhi
    cache nahi hota — agli baar Home screen khulne/refresh hone par turant
    dobara try hoga.
  - Isse bhi zaroori: user ke phone pe is bug ki wajah se **already ek
    khaali cache disk pe pada hoga** (aaj ki date ke saath) — sirf upar
    wala fix isse khud theek nahi karta (purana khaali cache read hoke
    return ho jaata, naya code kabhi chalta hi nahi). Isliye read-path
    mein bhi fix kiya: agar stored cache khaali nikle to use IGNORE karke
    fresh generate karo. Isse purana atka hua state bhi apne aap (agli
    Home-load pe) theek ho jaayega — app data clear karne ki zaroorat
    nahi.

- **`home_screen.dart`** — infinite-scroll ke "extra category sections"
  (`_kCategories`, sirf 12 fixed categories: Bollywood/Punjabi/etc.) sab
  12 dikhne ke baad **modulo (`% _kCategories.length`) se wapas Bollywood
  se cycle** kar jaate the — infinite loop mein wahi 12 sections (bilkul
  same static query, bilkul same results, kyunki har "X — aur gaane"
  section `YoutubeService.search()` — wahi function jo Search screen
  khud use karta hai — se banta hai) baar-baar dikhte rehte the. **Fix:**
  saare 12 ek-ek baar dikhne ke baad scroll simply ruk jaata hai, koi
  naya duplicate section nahi jodta — feed genuinely khatam hota hai.

- **`background_service.dart`** — asli race condition mili: `_playSong()`
  mein `_maybeAutoDownload(song)` aur `_autoCacheInBackground(song, url)`
  dono `unawaited` (parallel) chalte the, aur `_maybeAutoDownload` PEHLE
  call hota tha. `youtube_service.dart`'s `download()` mein pehle se
  "agar cache mein hai to seedha copy karo, dobara download mat karo"
  wala shortcut maujood tha (kisi purani session ka fix) — lekin cache
  abhi likha hi nahi gaya hota tha jab tak auto-download check karta,
  isliye cache-row hamesha khaali milta aur shortcut kabhi trigger hi
  nahi hota tha — har baar poora fresh (duplicate) network download hota
  tha. **Fix:** auto-download ab auto-cache ke COMPLETE hone ke *baad*
  (`.then()`) trigger hota hai — cache-row hamesha ready milega, cache-
  copy shortcut ab guaranteed use hoga (turant, koi extra network call
  nahi). Ek aur jagah bhi yehi missing tha — jab gaana already sirf-
  cache (download nahi) se seedha bajta hai (local-file-first path),
  wahan auto-download trigger hi nahi hota tha; ab wahan bhi hai.



**Ask (screenshot ke saath, download queue section circled):** download
abhi bhi slow feel hota hai chhote files ke liye bhi, aur us section ki
animation "lag" karti hai jab bhi chalti hai.

**Root cause:** ek 4MB file ka asli network-transfer time chhota hota hai
(seconds) — 1 minute mostly **resolve step** (source URL dhoondhna —
NewPipe → explode → Piped fallback chain) mein ja raha tha. `download()`
is poore resolve ke dauraan `onProgress` ko KABHI call nahi karta tha,
isliye UI hamesha static "0%" dikhata rehta tha — download slow nahi,
**silent** tha, jo "atka hua" jaisa feel hota tha.

**Fix:**
- `youtube_service.dart download()` — naya `onStatus(String)` param,
  `_resolveAudioStream()` ke already-maujood status-string mechanism ko
  yahan tak wire kiya (pehle ye kahin connect hi nahi tha). Cache-copy
  path aur network-resolve path, dono apna status bhejte hain ("Gaana
  dhoondha ja raha hai...", "Mil gaya — download shuru ho raha hai...",
  etc.)
- `download_queue_service.dart` — `statusOf(id)` naya getter; jab tak
  progress 0% hai, `downloads_screen.dart` ab title ke saath ye status
  dikhata hai (`"Sitaare — Gaana dhoondha ja raha hai..."`), static "0%"
  ki jagah.
- **Animation lag fix:** 5 parallel workers pehle apna-apna
  `notifyListeners()` bilkul turant (har % change pe) call karte the — kai
  workers ek saath fire karte to UI bahut zyada baar rebuild hoti, jo
  chhote-RAM devices pe stutter jaisa lagta tha. Ab progress/status
  updates max ~120ms me ek baar hi rebuild trigger karte hain
  (`_notifyThrottled()`); start/finish jaise events turant hi rehte hain.
- **Resolve pipeline internals (NewPipe/explode/Piped) ko bilkul nahi
  chheda** — NOTES.md warning ke mutabik. Ye sirf ek observability
  (status callback) + rebuild-throttle fix hai, resolve ka asli waqt
  same hi rahega, bas ab "chal raha hai" dikhega "atka hua" nahi.



**Ask:** "download bahut slow hai (1 gaana = 1 min)", "auto-download-on-play
jab gaana cache me pura aa chuka ho to usi cache ko download me daale,
dubara download na kare", "parallel me 5 gaane download ho sakein", "storage
wala error bhi theek karo".

**Root cause + Fix (sab jude hue hain):**
- `youtube_service.dart download()` pehle HAR download ke liye poora
  network resolve (NewPipe/explode/Piped) + fresh HTTP download karta tha —
  CHAHE wahi gaana abhi-abhi play hone ki wajah se already local CacheDB me
  maujood ho. Ye hi sabse bada slowness ka reason tha, aur "auto-download
  on play" wale case me to LITERALLY redundant tha (gaana already cache me
  hai, phir bhi dobara poora download ho raha tha).
  **Fix:** `download()` ab sabse pehle `CacheDB.instance.getRow(id)` check
  karta hai — agar mil jaaye, seedha us cached file ko naye path pe COPY
  kar deta hai (local disk copy, ~instant) aur `DownloadDB` me register kar
  deta hai — koi resolve, koi network call nahi. Naya `CacheDB.getRow()`
  method add kiya (poora record — title/artist/thumb/duration — file-path
  ke saath). Cache-copy fail ho (corrupt file, disk full) to normal
  network-download path pe hi fallback hota hai — kabhi silently fail nahi
  hota.
- `download_queue_service.dart` — `maxConcurrent` 3 → **5** (cache-reuse
  fix ke baad per-song average network load kam ho gaya hai, isliye 5
  parallel safe hai).
- `storage_service.dart` `getMusicDir()` — pehle HAR single download call
  pe public Music/ folder try karta tha (permission request + real
  write-probe, dono OS IPC calls) — bulk playlist download (jaise 98
  gaane) me agar permission pehle hi denied thi, ye same fail hone wala
  kaam 98 baar repeat karta tha (har baar wahi "Permission denied" log +
  extra latency). Ab result ek app-session ke liye cache hota hai
  (`_cachedMusicDir`) — sirf pehli baar hi real probe hota hai. **Honest
  note:** agar `MANAGE_EXTERNAL_STORAGE` ("All files access") user ne
  Settings me manually allow nahi kiya, to app-specific folder fallback
  (jo pehle se hi safe/working hai, bas file manager ke Music folder me
  nahi dikhta) hamesha use hoga — ye code se force nahi karaya ja sakta,
  user ko khud Settings > Apps > SurSathi > "All files access" se allow
  karna hoga agar public Music folder chahiye.



**Ask (screenshots ke saath):** "shayad ye home se aata nahi hai, na Daily
Mix dikh raha, na neeche aur playlist generate ho rahi — pehle jaisa hai."

**Root causes (dono real, alag-alag):**
1. **Daily Mix silently khaali reh sakti thi** — `daily_mix_service.dart`
   ka radio-pull (`getRadioQueue`) agar fail ho (network/extraction), purana
   code `catch (_) {}` se chup-chaap swallow kar leta tha, koi trace nahi
   milta tha ki kya hua. Fix: `DailyMixService.lastDebugInfo` naya field —
   batata hai "history hi nahi hai" vs "history hai par radio-pull fail
   hua (kis artist pe, kis wajah se)". `home_screen.dart` isse **sirf
   genuine failure ke case me** ek chhoti dim line dikhata hai (naya user
   jiski history hi nahi hai, uske liye section pehle jaisa chup hi rehta
   hai — koi noise nahi).
2. **"Infinite scroll" asal me FINITE tha** — `getHomeSections()` khud ek
   hi call me poora feed exhaust kar leta hai (koi real "next page" milta
   hi nahi, upar wala HONESTY NOTE dekho) — matlab `_homeSections` khatam
   hote hi scroll literally "dead end" ho jaata tha, koi naya content kabhi
   nahi aata tha, chahe user kitna bhi scroll kare. Isi wajah se lag raha
   tha "kuch generate nahi ho raha, pehle jaisa hai."
   **Fix:** curated `_homeSections` khatam hone ke baad, feed ab
   `_kCategories` (12 categories) ko ek-ek karke asli `search()` se fetch
   karke naye "... — aur gaane" sections banata rehta hai, aur 12 category
   khatam hone par wapas cycle kar deta hai — matlab scroll ab sach me
   kabhi khatam nahi hota (fallback "Trending Now" case me bhi same lagta
   hai). Ye extra category-search `search()` use karta hai (already stable,
   sab jagah use hota hai) — **resolve/CDN-header pipeline ko chhua nahi
   gaya**.



**Ask:** download duplicate-check pakka ho, downloads app uninstall karne
par bhi rahein, cache default 3GB ho, current gaane ke saath pichla gaana
bhi cache me rahe aur agle 2 upcoming gaane bhi preload ho jayein.

**Fixes:**
- `background_service.dart` `_resolveAndPlay()` — ab pehle DownloadDB phir
  CacheDB me local file check karta hai; mile to seedha `player.setFilePath()`
  se bajata hai (koi NewPipe/explode/Piped resolve hi nahi — offline bhi
  chalega, aur "pehle se hai to phir se download/resolve mat karo" wala
  duplicate-safety yahin se guaranteed hoti hai).
- Cache-hit se play hone par `CacheDB.update(lastPlayed: now)` — isse
  replay hua/pichla gaana LRU eviction me "fresh" maana jaata hai aur jaldi
  nahi hatata (pehle `last_played` kabhi update hi nahi hota tha, ye ek
  real bug tha).
- `_prefetchNext()` ab sirf agle gaane ka URL cache nahi karta — agle
  **2** upcoming gaane disk pe bhi cache ho jaate hain (`_prefetchOne`),
  aur agar wo pehle se download/cached hai to kuch nahi karta (no
  duplicate work).
- `download_db.dart` / `cache_db.dart` — naya `getFilePath(id)` method
  (file abhi disk pe hai ya nahi, verify karke).
- `playlist_detail_screen.dart` single-song `_download()` me duplicate
  check add kiya (pehle sirf "Download All" check karta tha, single
  download nahi). `youtube_service.dart download()` me bhi root-level
  duplicate check add kiya (defense-in-depth, koi bhi caller miss kare
  to bhi safe).
- `cache_service.dart` default limit 2GB → **3GB**; `cache_manager_screen.dart`
  slider me 3GB option add kiya.
- **Uninstall-persistence:** `AndroidManifest.xml` me
  `MANAGE_EXTERNAL_STORAGE` permission add kiya + `storage_service.dart`
  ke `getMusicDir()` me request kiya. Isse pehle Android 11+ (scoped
  storage) pe public `Music/SurSathi` folder me likhna fail ho jaata tha
  aur app app-specific `Android/data/<package>/` folder pe fallback karta
  tha — jo **uninstall pe khud delete ho jaata hai**. Ab permission grant
  hone par asli public Music folder use hoga (uninstall-safe); deny kare
  to purana safe fallback abhi bhi kaam karega (bas uninstall pe delete
  ho jayega, jaisa pehle tha).



**Ask:** "download icon pe dikhe ki gaana pehle se download hai", "radio mode
on hai to uska bhi pata chale", "sleep timer on hai to uska bhi", aur ye
sabme (playlist screen samet) consistent ho.

**Fixes:**
- `song_card.dart` — naya `isDownloaded` param; true hone par icon
  `download_done_rounded` + green, warna pehle jaisa grey `download_rounded`.
  Default `false` hai, isliye ye jin screens me pass nahi hua wahan behaviour
  bilkul same raha.
- `playlist_detail_screen.dart` — `_downloadedIds` set (DownloadDB se load,
  single + bulk download ke baad update) → `SongCard(isDownloaded: ...)`.
- `full_player_screen.dart` — download chip ab `DownloadDB.instance.exists()`
  FutureBuilder se green/filled dikhta hai (HeartButton wale isLiked pattern
  jaisa hi). Radio chip `queueService.radioMode` se green + tap karne par
  ab radio band bhi kar sakta hai (pehle sirf start hi hota tha). Sleep-timer
  chip `_sleepTimer != null` se green/filled.
- `mini_player.dart` — same download + radio icon state fix.
- `queue_service.dart` — **bug mila:** `enableRadioMode()`/`disableRadioMode()`
  kabhi `notifyListeners()` call hi nahi karte the, isliye `radioMode` UI me
  reactively update hi nahi ho sakta tha chahe kuch bhi try karo. Ab dono
  jagah `notifyListeners()` add kiya.
- `full_player_screen.dart` sleep timer — `_startSleepTimer`/`_cancelSleepTimer`
  pehle koi `setState()` hi nahi karte the (icon kabhi refresh nahi hota),
  aur timer khud fire hone (auto-pause) ke baad bhi `_sleepTimer` null nahi
  hota tha (icon hamesha "on" dikhta reh jaata). Dono fix kiye.



**Problem 1 — Next par 10s delay (network fast hone par bhi):** `skipToNext()`
har baar tap hone ke BAAD hi poora resolve pipeline (NewPipe native →
youtube_explode_dart → Piped backup, teeno sequential) shuru karta tha.
Chahe network kitna bhi fast ho, ye poora chain (native invoke + har
candidate ka `_verifyPlayable()` HTTP check) kuch second le hi leta hai —
aur next tap hone tak iska koi part pehle se nahi hota tha.

**Fix (`background_service.dart`):** Naya `_urlCache` (Map<videoId, url>) +
`_prefetchNext()`. Jaise hi current gaana successfully play hona shuru
hota hai, queue ka agla gaana (`QueueService.upcoming.first`) turant
background me resolve hona shuru ho jaata hai (silently, UI/state ko touch
kiye bina). `skipToNext()` → `_resolveAndPlay()` sabse pehle is cache me
dekhta hai — hit mile to seedha wahi URL se play (koi naya network/native
call nahi, ~instant); miss ho (prefetch abhi complete nahi hua, ya user ne
bahut jaldi 2-3 baar skip kar diya) to purana 3-attempt resolve chain
normal fallback ki tarah chalta hai.

**Problem 2 — kuch gaane bilkul nahi chalte (silent 403):** `_verifyPlayable()`
aur `player.setUrl()` dono koi custom `User-Agent`/`Referer`/`Origin` header
nahi bhejte the. googlevideo CDN ke kuch stream URLs bina in headers ke
403 de dete hain — `_verifyPlayable` isko "FAIL" mark kar deta tha, saare
candidates/layers isi tarah fail ho jaate, aur 3 attempts (har ek 45s tak)
poore hone ke baad hi error snackbar aata — itni der wait karne tak user
already navigate kar chuka hota, isliye "silent fail" jaisa feel hota tha.

**Fix (`youtube_service.dart`):** `cdnHeaders` (Chrome UA + youtube.com
Referer/Origin) add kiya, `_verifyPlayable()`, `player.setUrl()`
(background_service.dart), aur `download()` ke http request — teeno me
inject kiya.

**Bonus:** NewPipe native layer (`_audioViaNewPipe`) ka timeout 30s → 8s
(user ke fast-network case me stuck/hang jaldi detect ho aur agli layer
try ho).

**Not changed:** `_newPipeLock` mutex jaanbujhke wapas nahi laaya — Batch 22
me isko hataya gaya tha kyunki native Kotlin plugin (WebView nahi) already
thread-safe hai; lock dobara dalna sirf prefetch + skip dono ko slow karega,
crash-safety me koi naya fayda nahi (wo crash-class Batch 22 me hi khatam
ho chuki thi).

---

## Post-Batch-22 Fix (2026-09-16) — REAL crash found via new in-app crash logger

User ne crash logger (v10 build) se pehli baar asli crash log nikaal ke
bheja:
```
android.app.RemoteServiceException: Bad notification(tag=null, id=1124)...
Couldn't inflate contentViews
java.lang.IllegalArgumentException: setShowActionsInCompactView: action 1
out of bounds (max 0)
```
Ye confirm karta hai ki asli crash NewPipeExtractor/R8 wala nahi tha —
ek bilkul alag, system-level **media-notification** crash hai jo Dart
try/catch se kabhi pakda nahi ja sakta (crash logger na hota to isse
guess karna almost impossible tha).

**Root cause (`lib/services/background_service.dart`, `playWithRetry()`):**
`_broadcastState()` normal playback ke waqt `controls` ko 4 items
(previous/play-pause/stop/next) set karta hai aur
`androidCompactActionIndices: [0, 1, 3]` (matlab compact notification me
index 0, 1, 3 wale controls dikhao). Lekin `playWithRetry()` jab bhi naya
gaana load karta hai, `controls` ko sirf `[MediaControl.stop]` (1 item,
sirf index 0) tak shrink kar deta tha — bina `androidCompactActionIndices`
ko bhi update kiye. `copyWith()` purani `[0, 1, 3]` value carry-forward kar
deta, matlab notification ko bola jaa raha tha index 1 aur 3 wale actions
compact view me dikhao, jabki ab controls list me sirf 1 item (index 0)
tha — Android isi mismatch pe `RemoteServiceException` de ke **poora app
process crash** kar deta hai. Isi wajah se crash "har naya gaana load hote
waqt" consistently hota tha (normal transition ho ya tap se) — bilkul
Batch-20 wale purane symptom jaisa dikhta tha, lekin root cause bilkul
alag nikla.

**Fix:** `playWithRetry()` ke us `copyWith()` call me
`androidCompactActionIndices: const [0]` explicitly add kiya — jab bhi
`controls` shrink/badle, compact indices ko bhi USI list ke saath sync
rakhna zaroori hai.

**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v11`.
**Test on real device:** naya gaana tap karke turant confirm karo — is
baar crash NAHI hona chahiye. Agar phir bhi ho, crash logger (Debug screen
→ Load + Share Crash Log) se naya log bhejo.

---

## Post-Batch-22 Addition (2026-09-16) — In-app crash logger (PC/logcat nahi hai)

User ke paas PC nahi hai, aur is device (Redmi Note 7, MIUI, Android 10)
ke Developer Options me "Bug report" tool bhi missing/hidden hai — matlab
crash debug karne ka koi standard bahri tarika available nahi tha.

**Fix — app apna khud ka crash catcher rakhti hai ab:**
- Naya `android/app/src/main/kotlin/com/sursathi/sursathi/CrashLogger.kt`
  — `Thread.setDefaultUncaughtExceptionHandler` global install karta hai
  (MainActivity.onCreate() ke sabse pehle statement se, taaki startup
  crash bhi pakde). Koi bhi uncaught `Throwable` (Exception YA Error, dono
  — dekho upar wala R8 crash fix jahan `Error` hi asli issue tha) poore
  stack trace ke saath `getExternalFilesDir(null)/sursathi_crash_log.txt`
  me likh diya jaata hai (koi runtime permission nahi chahiye), phir
  purana/system default handler ko call kiya jaata hai (normal crash-dialog
  behaviour barkarar rehta hai).
- `MainActivity.kt`: naya MethodChannel `com.sursathi.sursathi/crashlog`
  (`getPath` / `clear`) — Dart ko exact file path deta hai.
- `debug_screen.dart`: naya "Crash Log" section (build-marker box ke turant
  baad) — "Load + Share Crash Log" button file read karke turant
  `share_plus` se Android share-sheet khol deta hai (WhatsApp/Telegram/
  Files, kuch bhi) — koi ADB/logcat/Bug-Report zaroori nahi ab. "Clear log"
  bhi hai taaki purane crashes naye se mix na ho.
**Test on real device:** ek baar crash reproduce karke Debug screen se
turant check karna — file turant milni chahiye, empty/missing nahi.
**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v10`.

---

## Post-Batch-22 Fix (2026-09-16) — User re-report: still crashing on v28 (native NewPipeExtractor R8 crash)

User ne v28 test karke bataya crash abhi bhi ho raha hai. Batch 22 (neeche)
ka native Kotlin plugin is session me kabhi compile/run nahi hua tha
(explicitly note kiya gaya tha), isliye root cause wahin dhoonda:

**Root cause (`NewPipeAudioChannel.kt`):** `resolveAudioStream()` ka
aakhri catch block sirf `catch (e: Exception)` tha. Release build me R8
minify hamesha ON hai, aur `proguard-rules.pro` me sirf
`org.schabi.newpipe.extractor.timeago.patterns.**` (aur Rhino) keep kiya
gaya tha — poora `org.schabi.newpipe.extractor` package nahi. NewPipeExtractor
apne andar reflection/service-loading se poore package ki classes use karta
hai (`StreamInfo`, `ServiceList`, `Service` subclasses); agar R8 inme se
kisi ko obfuscate/strip kar de to runtime pe `NoSuchMethodError`/
`NoClassDefFoundError` aata hai — ye **`Error` hai, `Exception` nahi**,
isliye `catch (e: Exception)` ise pakadta hi nahi tha aur process crash ho
jaata tha (bilkul usi purani WebView-crash class jaisa jo Dart try/catch
se bhi nahi pakdi jaati thi — bas ab wahi pattern native Kotlin side pe
reappear hua).

**Fix:**
1. `proguard-rules.pro`: `-keep class org.schabi.newpipe.extractor.** { *; }`
   add kiya (poora package, na ki sirf timeago.patterns) — taaki R8 kuch
   bhi strip/rename hi na kare.
2. `NewPipeAudioChannel.kt`: aakhri catch ko `catch (e: Exception)` se
   `catch (e: Throwable)` kiya — ab agar phir bhi koi `Error`-type cheez
   aaye (kisi aur wajah se), wo bhi ek graceful `UNKNOWN` error result ban
   ke Dart tak jaayegi, process crash nahi hoga.

**Build marker:** `NEWPIPE-NATIVE-2026-09-16-v9` (debug_screen.dart).

**Agar v29 me bhi crash ho:** ab crash Dart-catchable nahi hai matlab ye
NewPipe wala code-path nahi hai — real device se **logcat** (`adb logcat`
ya Play Protect/crash-report) chahiye hoga exact stack trace ke liye,
guess karke aur fix karna is point ke baad reliable nahi rahega.

---

## Batch 22 (2026-09-16) — Option C: native NewPipeExtractor plugin (no more WebView)

Batch 21 ke end me user ke saath 3 options discuss huye the (audio-fetch
crash ko HAMESHA ke liye khatam karne ke liye, jaisa OuterTune/OpenTune
karti hain): (A) poora app native Kotlin me rewrite, (B) OpenTune/OuterTune
fork karo, (C) app waisa hi raho, sirf audio-fetch wala risky hissa apna
native plugin se replace karo. User ne **Option C** choose kiya.

**Kya badla:**
- `newpipeextractor_dart` (Flutter wrapper, jo andar `flutter_inappwebview`
  WebView ke through signature-cipher solve karta tha) aur uski
  `flutter_inappwebview` dependency — dono `pubspec.yaml` se HATA DI GAYI
  hain. Yahi WebView native View creation hi Batch 20/21 ke "kuch gaane
  HAMESHA crash/fail" ka asli root cause thi (native process-level crash,
  Dart try/catch se na pakड़ me aane wala).
- Naya native Android plugin (koi third-party Flutter package nahi, hamara
  apna Kotlin code):
  - `android/app/src/main/kotlin/com/sursathi/sursathi/newpipe/NewPipeDownloader.kt`
    — NewPipeExtractor ke liye `Downloader` implementation, seedha OkHttp
    se (NewPipeExtractor ke apne quickstart docs ka pattern). Koi WebView
    nahi.
  - `android/app/src/main/kotlin/com/sursathi/sursathi/newpipe/NewPipeAudioChannel.kt`
    — `MethodChannel("com.sursathi.sursathi/newpipe")` ka handler.
    `StreamInfo.getInfo()` (asli NewPipeExtractor Java library) ko seedha
    call karta hai — bilkul OuterTune/OpenTune jaisa architecture. Audio-
    only stream na mile to muxed fallback (jaisa Dart-side pehle karta
    tha). Har exception type (ContentNotAvailable/GeoRestricted/
    AgeRestricted/ReCaptcha/Extraction/Network/Unknown) ka apna error-code
    hai taaki debug screen pe exact reason dikhe.
  - `MainActivity.kt` me `configureFlutterEngine()` override karke channel
    register kiya gaya hai.
  - `android/app/build.gradle` me `com.github.teamnewpipe:NewPipeExtractor:v0.26.4`
    aur `com.squareup.okhttp3:okhttp:4.12.0` explicit dependencies add kiye
    (pehle ye sirf `newpipeextractor_dart` ki transitive dependency ki
    tarah aate the — JitPack repo + proguard rules already project me
    maujood the, isliye unme koi change nahi karna pada).
- `lib/services/youtube_service.dart`: `_audioViaNewPipe()` ab
  `npe.VideoExtractor.getStream()` ki jagah upar wale native MethodChannel
  ko call karta hai. Purana `_newPipeLock` mutex (WebView-instance-limit
  crash rokne ke liye tha, dekho Batch-20 notes) poori tarah HATA DIYA GAYA
  — native extraction thread-safe hai, serialize karne ki zaroorat nahi.
  `_resolveAudioStream()` ka order bhi wapas NewPipeExtractor-first kar
  diya gaya (Batch 21 me safety ke liye explode-first kiya gaya tha; ab
  crash-risk hi khatam ho chuka hai to NewPipeExtractor ke behtar
  bypass-rate ka fayda wapas milega) — `_audioViaExplode()` ab fallback
  hai, Piped backup teesra layer.
- `kBuildMarker` (debug_screen.dart): `NEWPIPE-NATIVE-2026-09-16-v8`.

**Zaroori — TEST NAHI HUA (CI pe pehli baar banega):** Ye native Kotlin
code is session me sirf docs/source-reference se likha gaya hai, kabhi
compile nahi hua (is environment me Android SDK/Gradle available nahi
hai). Pehla GitHub Actions build in sab pe compile-error de sakta hai
(Kotlin syntax, NewPipeExtractor API signature mismatch specific version
me, ya Gradle dependency resolution) — agar aisa ho to build log yahan
paste karna, standard batch-by-batch fix flow se theek karenge (jaisa
pichle saare Gradle/build fixes hue hain).

**License:** NewPipeExtractor khud GPL-3.0 hai (pehle se documented tha
`newpipeextractor_dart` ke liye bhi) — ab bhi wahi obligation hai, bas
dependency pubspec.yaml ki jagah build.gradle me hai.

---

## Batch 21 (2026-09-16) — User re-report on v23-fixed: "kuch bhi nahi badla"

User ne v23-fixed test karke bataya: (a) crash ab bhi hota hai, LEKIN
per-song CONSISTENT hai (ek gaana hamesha chalta hai, doosra hamesha
crash/fail) — matlab Batch 20 ka overlap-mutex fix (#49/#51, jo already
verified present hai is zip me) apni jagah sahi hai, bas ye ALAG root
cause hai jise wo fix cover nahi karta; (b) search me abhi bhi purane/
generic gaane; (c) YouTube-se-fetch (download bhi, playback bhi) theek se
kaam nahi kar raha. Fresh build confirm kiya gaya (purana APK/cache wali
possibility nahi hai).

**Research kiya gaya (OuterTune/OpenTune — established Kotlin YT Music
clients — kya use karte hain):** Ye apps NewPipeExtractor ko seedha native
Kotlin/Java se call karti hain (koi Flutter-jaisa WebView-wrapper plugin
nahi) aur apna khud ka actively-maintained `innertube` Kotlin module rakhti
hain. Isi research me pata chala ki humara `newpipeextractor_dart`
(pubspec me `^2.0.2` pinned) khud bahut naya/chhota package hai (pehla
release-family ~mid-2026, pub.dev par sirf ~2 likes/~150 downloads total —
kam real-world testing) — matlab per-video native crash bugs iske andar
already likely hain jo Dart-side try/catch se kabhi pakde nahi ja sakte
(dekho pehle se documented "native process-level crash" note upar). Iski
apni changelog (2.0.1) confirm karti hai ki YouTube "SABR enforcement" ke
karan pehle stream-extraction reject kar raha tha — matlab pubspec ka
`^2.0.2` constraint already sahi/latest version maangta hai jisme ye
upstream fix included hai; agar phir bhi fetch fail ho raha hai, to
package ki apni immaturity (kuch specific videos pe) sabse zyada likely
wajah hai, na ki version-pinning.

**Fix #1 (`youtube_service.dart`, crash + fetch dono):**
`_resolveAudioStream()` ka order badla — pehle `_audioViaExplode()` (pure
Dart, koi native WebView nahi, isliye process-level crash NAHI kar sakta)
try hota hai, `_audioViaNewPipe()` (WebView-based, crash-risk) ab sirf
FALLBACK hai jab explode fail ho. Isse jo bhi gaane explode se resolve ho
jaate hain (crash-prone path chhua hi nahi jaata) unke crash/fetch-fail
dono khatam ho jaana chahiye; jo explode pe fail hote hain unhi ke liye
NewPipeExtractor ka crash-risk ab bhi accept kiya ja raha hai (trade-off:
thoda kam success-rate kuch videos pe, crash na hone ke badle me).

**Fix #2 (`innertube_client.dart`, purane/generic search):**
`_refreshConfig()` (key/clientVersion self-heal) pehle sirf REACTIVE tha
(sirf HTTP 400/403 pe chalta tha). Risk: agar YouTube stale clientVersion
(hardcoded default ~21 mahine purana) ko seedha reject na kare, bas
kam-accurate/generic 200-OK results de de, to self-heal kabhi trigger hi
nahi hota — "purane gaane" bina kisi error signal ke chalte rehte. Ab
`_post()` session ki PEHLI call se pehle hi (chahe wo call fail ho ya
success) ek baar proactively refresh try karta hai.

**Test on real device (zaroori):** Fix #1 crash ke liye sabse important
hai — same "hamesha crash hone wala" gaana dobara try karna. Agar ab bhi
crash ho (explode bhi us specific video pe kisi wajah se NewPipe tak
pahunch jaata hai), logcat capture karna zaroori hoga real root cause
isolate karne ke liye — is level ka native crash bina device log dekhe
guess karna mushkil hai.

---

## ⚠️ GPL-3.0 LICENSE WARNING (added 2026-09-16, v4) — READ BEFORE PUBLISHING
`newpipeextractor_dart` (ab primary audio backend) is GPL-3.0, kyunki ye
GPL-3.0 NewPipeExtractor (Java) library ko link karta hai. **Iska matlab:
poori app ab GPL-3.0 ke tahat aati hai** agar tum ise kisi ko distribute
karte ho (Play Store, APK sharing, kuch bhi) — GPL-3.0 copyleft hai, isliye
poore app ka source code publicly available karna legally zaroori ho jaata
hai. Agar app closed-source rakhni hai:
- Ya to `newpipeextractor_dart` hata do (wapas sirf youtube_explode_dart +
  Piped backup pe niर्भर, jo abhi kam reliable hain — dekh youtube_service.dart
  ke comments), ya
- App ko khud GPL-3.0 ke tahat open-source publish karo, ya
- Koi non-copyleft alternative dhoondo.
Ye purely legal/licensing decision hai, code fix nahi — khud decide karo
kaunsa tradeoff chahiye.

## RESOLVED IN BATCH 17-fix (post-Batch-18 user reports, 2026-09-16)
- **Playlist cards khaali/"Kuch nahi mila"**: `dart_ytmusic_api`'s
  `getPlaylistVideos()` khud package ke README me "not working as
  expected — Invalid request error, under investigation" declare kiya
  hua hai (package ka apna bug). Fix: `getYtMusicPlaylistTracks()` ab
  isme fail/khaali hone par playlist ke title+subtitle se normal
  `search()` fallback karta hai (`live_playlist_screen.dart` se
  `fallbackTitle`/`fallbackSubtitle` pass hote hain) — approximation hai
  (exact original tracklist nahi), lekin screen kabhi khaali nahi
  rahegi.
- **Search me "purane"/generic YouTube results (YT Music jaisa nahi)**:
  `search_screen.dart` `onProgress` callback kabhi wire hi nahi hua tha,
  isliye pata nahi chalta tha ki Layer 1 (YT Music) fail ho raha hai ya
  Layer 2 (generic YouTube search, jo "purane"/kam-relevant results deta
  hai) use ho raha hai. Ab Songs tab ke results ke upar ek chhota
  "Source: YouTube Music" / "Source: YouTube (generic...)" debug badge
  dikhta hai — agar baar-baar "generic" dikhe, iska matlab YT Music
  layer (`searchSongs`) is device/query pe consistently fail ho raha
  hai, real fix ke liye wo case reproduce karke dekhna hoga (package
  "early development, may be unstable" khud bolta hai).
- **Full player me download/radio button missing**: Mini player
  (`mini_player.dart`) me pehle se the, full player screen me nahi.
  Fix: `full_player_screen.dart` me same behaviour (in-progress spinner
  ke saath) add kiya — chip row ab 6 items (heart, download, radio,
  queue, timer, lyrics) hai, isliye `LayoutBuilder` +
  `SingleChildScrollView` se wrap kiya taaki chhoti screens pe overflow
  na ho (fit ho jaaye to pehle jaisa hi evenly-spaced dikhta hai, na ho
  to side-scroll).

## RESOLVED IN BATCH 16 (CI build failure, 2026-09-16)
- `lib/services/youtube_service.dart`: `SongDetailed`/`VideoDetailed`/
  `PlaylistDetailed` "isn't a type" errors — `dart_ytmusic_api`'s
  `yt_music.dart` only exports the `YTMusic` class; those result types
  live in the separate `types.dart` library. Fix: added
  `import 'package:dart_ytmusic_api/types.dart';`.
- `lib/screens/full_player_screen.dart:315,318`: `mediaItem.duration`
  accessed without a null check — `mediaItem` here is `mediaSnap.data`
  from a `StreamBuilder<MediaItem?>`, so it's `MediaItem?`. Fix: changed
  both to `mediaItem?.duration`.
- `lib/services/background_service.dart` (`AudioServiceConfig`):
  `audio_service` has an internal assert that `androidNotificationOngoing:
  true` requires `androidStopForegroundOnPause: true` (otherwise it's a
  no-op, because an active foreground service already forces the
  notification to be ongoing) — this combo now throws at const-eval time
  instead of silently no-opping. Fix: removed `androidNotificationOngoing:
  true` (default `false`); `androidStopForegroundOnPause: false` alone
  already gives the intended behavior (persistent foreground
  notification/controls through pause).

## RESOLVED IN BATCH 15
- assets/ folder missing build fail de raha tha — pubspec me comment kar diya
- Android scaffold incomplete tha — build.yml me flutter create step add

Ye file un cheezon ke liye hai jo pura kaam karti hain lekin ek chhota
sa gap, assumption, ya limitation rakhti hain — taaki koi bhi (naya
instance ya khud future-me) ek jagah dekh ke sab pata kar sake.

---

### 1. `StorageService.getFreeSpaceBytes()` — Batch 4
**File:** `lib/services/storage_service.dart`
**Issue:** Device ka free storage space nikalne ke liye koi disk-space
plugin (jaise `disk_space` ya `storage_info_plus`) pubspec me nahi tha.
**Filhaal:** Function `-1` return karta hai ("Unknown"). UI is value pe
graceful fallback dikhaye (e.g. "Free space: Unknown").
**Fix:** Agar real value chahiye to pubspec me disk-space plugin add
karna hoga aur is function ko update karna hoga.

---

### 2. `flutter_local_notifications` dependency — Batch 5
**File:** `pubspec.yaml`
**Issue:** `notification_service.dart` (Batch 5) ko is package ki zaroorat
thi, lekin ye pubspec.yaml me pehle se nahi tha.
**Fix kiya:** `flutter_local_notifications: ^17.2.1` pubspec me add kar
diya gaya hai. Repo me push karne ke baad `flutter pub get` chalana.

---

### 3. `YoutubeService` — client/API surface assumption — Batch 5
**File:** `lib/services/youtube_service.dart`
**Note:** `youtube_explode_dart` ke `YoutubeApiClient` (androidVr, ios,
mweb, web, android) aur streaming APIs fast-changing hain — YouTube
side se breaking changes aa sakte hain. Agar `search()`/`getAudioUrl()`
kaam karna band kar de, sabse pehle `youtube_explode_dart` ko latest
version pe update karna aur uske changelog/API dekhna.
**Storage permission:** Android 13+ pe scoped storage ke karan
`Permission.storage` request fail bhi ho sakti hai bina real impact ke
(kyunki app apne hi Music/SurSathi folder me likh raha hai) — is wajah
se `download()` me permission fail hone pe bhi aage try karte hain.

---

### 4. Auto-cache on stream play — Batch 5
**File:** `lib/services/background_service.dart`
**Note:** Jab koi song stream se play hota hai, background me
`dart:io HttpClient` se poora stream URL download karke cache folder me
save hota hai, fir `CacheService.cacheSong()` call hoti hai. Ye poora
process **await nahi hota** (fire-and-forget) taaki playback block na ho.
Agar download beech me fail ho jaye, silently ignore hota hai — koi user
facing error nahi aata (jaanbujhke, kyunki playback already chal raha
hota hai).

---

---

### 5. Gradient constant naming — Batch 7
**File:** `lib/theme/colors.dart`
**Issue:** Batch 7 prompt ne `kGreenBlueGrad` naam se ek top-level gradient
constant maanke chala, lekin actual `colors.dart` (Batch 2 se) me gradients
`AppGradients` class ke andar hain (`AppGradients.greenBlue`,
`AppGradients.bluePurple`) — koi top-level `kGreenBlueGrad`/`kBluePurpleGrad`
nahi hai.
**Filhaal:** `rotating_vinyl.dart` aur `animated_play_button.dart` me seedha
`kGreen`/`kBlue` colors se inline `LinearGradient`/`RadialGradient` bana diya
gaya hai — koi naya constant define nahi kiya.
**Fix (optional):** Agar aage `kGreenBlueGrad` naam se hi refer karna hai to
`colors.dart` me `AppGradients.greenBlue` ko us naam se bhi export/alias
karna hoga.

---

### 6. `CacheIndicator` fade-out — Batch 7
**File:** `lib/widgets/cache_indicator.dart`
**Note:** `isCached == false` par widget seedha `SizedBox.shrink()` return
karta hai (spec ke mutabik), isliye "fade out" nahi hota — sirf fade-IN
hota hai jab `isCached` true ho jaata hai. Agar smooth fade-out bhi chahiye
to widget ko hamesha mount rakhna hoga (opacity 0/1 toggle karke, shrink
na karke).

---

### 7. Onboarding flow order — RESOLVED Batch 14A
**Files:** `lib/screens/splash_screen.dart`, `onboarding_screen.dart`,
`language_screen.dart`, `permission_screen.dart`, `taste_screen.dart`,
`lib/main.dart`
**Status:** Chain ab end-to-end sahi hai: `Splash → Onboarding → Language →
Permission → Taste → Home`. `language_screen.dart` ka Continue target
`OnboardingScreen` se `PermissionScreen` kiya gaya (ye hi purane loop ka
asli source tha — `onboarding_screen.dart` ko khud badalna nahi pada, wo
pehle se hi `LanguageScreen` target kar raha tha, waise hi
`permission_screen.dart` bhi pehle se hi `TasteScreen` target kar raha tha
Next aur Skip dono pe). `taste_screen.dart` ab `onboarding_done=true` set
karke real `HomeScreen` pe jaata hai (purana placeholder hata diya gaya).
`splash_screen.dart` 2s ke baad `onboarding_done` check karke `HomeScreen`
(agar pehle se onboard ho chuka hai) ya `OnboardingScreen` (pehli baar) pe
jaata hai. `main.dart` me ek naya `_Boot` widget bhi add kiya gaya jo app
start hote hi `onboarding_done` check karta hai — agar already onboard ho
chuka hai to splash animation bhi skip karke seedha `HomeScreen` dikhata
hai (returning users ke liye faster open).

### 8. `kGreenBlueGrad` / `kBgGrad` still don't exist — Batch 8
**Files:** `lib/screens/splash_screen.dart`
**Issue:** Batch 8 prompt ne phir se in naamo se top-level gradient
constants maan liye (jaisa Batch 7 me hua tha — dekho note #5 upar).
**Filhaal:** Splash background gradient inline `LinearGradient(colors:
[kBg, kBgElev, kBg])` se banaya gaya hai, koi naya constant define nahi
kiya gaya.

### 9. Permission "Not asked" vs "Denied" distinction — Batch 8
**File:** `lib/screens/permission_screen.dart`
**Note:** `permission_handler` ek baar bhi request kiye bina bhi status ko
kabhi-kabhi `denied` hi return karta hai (especially Android pe), isliye
initial load pe sirf `isGranted` check karke baaki sabko "Not asked" maana
gaya hai. "Allow All" dabane ke baad hi real "Denied" state dikhti hai (jab
tak wo initial load se pehle app ke kisi aur session me deny na kiya gaya ho).

---

### 10. Mini player wrapper duplicated across 4 screens — Batch 9
**Files:** `home_screen.dart`, `search_screen.dart`, `library_screen.dart`,
`downloads_screen.dart`
**Note:** Spec me sirf 4 files allowed thi is batch me, isliye ek chhota
private `_MiniPlayerBar`/`_HomeMiniPlayerBar` widget (QueueService.currentSong
+ LikeService.isLiked FutureBuilder + `MiniPlayer` widget) har file me alag
se duplicate kiya gaya hai (identical code, 4 jagah). **Fix (optional):**
future batch me ek shared `lib/widgets/mini_player_bar.dart` bana ke sab
screens usko import karein.

### 11. `SongCard` me `onDelete` param nahi hai — Batch 9
**File:** `lib/screens/downloads_screen.dart`
**Issue:** Batch 9 prompt ne `SongCard` par ek `onDelete` callback maan liya,
lekin actual widget (Batch 6 se) me sirf `onTap/onPlay/onDownload/onLike` hain
— koi `onDelete` nahi.
**Filhaal:** Downloads screen me `onDownload` callback hi delete-confirm
dialog trigger karta hai (kyunki already-downloaded item pe dobara "download"
ka koi matlab nahi), aur ek `Dismissible` (swipe-to-delete) bhi wrap kiya gaya
hai as primary gesture. Dono hi `_confirmDelete()` call karte hain.

### 12. FullPlayer navigation — RESOLVED Batch 10
**Files:** sab 4 screens ke `_MiniPlayerBar`
**Status:** `FullPlayerScreen` ab ban chuki hai (Batch 10). Sab 4 jagah ka
SnackBar placeholder hata ke real `Navigator.push(MaterialPageRoute(builder:
(_) => const FullPlayerScreen()))` laga diya gaya hai.

### 13. Home screen abhi app ka root nahi hai — RESOLVED Batch 14A
**File:** `lib/main.dart`
**Status:** `main.dart` me ab `_Boot` widget hai jo `onboarding_done` check
karta hai aur us hisaab se `HomeScreen` ya `SplashScreen` dikhata hai (dekho
NOTES.md #7). `HomeScreen` ab onboarding chain ke aakhri step
(`taste_screen.dart`) se bhi reachable hai.

### 14. "Recently Played" section skip kiya — Batch 9
**File:** `lib/screens/library_screen.dart`
**Issue:** Spec ne "Recently Played — QueueService history (agar available)
ya skip" bola. `QueueService` sirf current queue + index rakhta hai, koi
alag "history" list nahi (sirf `upcoming` getter hai, jo history nahi hai).
**Filhaal:** Section skip kar diya gaya hai, jaisa spec ne khud allow kiya
tha is case ke liye.

---

### 15. Equalizer — UI + save only, koi real DSP nahi — Batch 10
**File:** `lib/screens/equalizer_screen.dart`
**Issue:** `just_audio` me built-in cross-platform equalizer DSP nahi hai
(Android pe `just_audio`'s Android-specific `AndroidEqualizer` class use ho
sakta hai, lekin wo iOS pe kaam nahi karta aur `background_service.dart`
ke `AudioPlayer` ke saath abhi wire nahi kiya gaya).
**Filhaal:** Saare bands/bass-boost/surround/reverb values sirf UI state
hain aur `SharedPreferences` (`equalizer_settings` key) me save hote hain
— actual playback audio in values se affected nahi hota, jaisa spec ne khud
allow kiya tha ("Functional audio DSP optional rakho").
**Fix (agar chahiye):** Android-only `AndroidEqualizer` (just_audio) ko
`audioHandler.player` ke audio pipeline me attach karna hoga.

### 16. Equalizer screen — kahin se navigate nahi hota — Batch 10
**File:** `lib/screens/equalizer_screen.dart`
**Issue:** Spec ne sirf 4 screens banane ko bola (full_player, queue,
lyrics, equalizer) — kisi settings/menu se `EqualizerScreen` open karne
ka koi entry point maangi hi nahi gayi thi, aur `full_player_screen.dart`
ke 4 chips me equalizer ka koi icon spec me nahi tha (heart/queue/timer/
lyrics hi the).
**Filhaal:** Screen compile hoti hai aur standalone kaam karti hai, bas
kisi bhi jagah se `Navigator.push` nahi hota. Batch 13 (Settings) me ise
kahin se link karna hoga.

---

### 17. `PlaylistDB` ka real API, Batch 11 prompt ke assumption se alag hai — Batch 11
**File:** `lib/db/playlist_db.dart` (Batch 3 se, is batch me touch nahi kiya)
**Issue:** Batch 11 prompt ne in signatures ko maan liya tha:
`createPlaylist(name, emoji, gradient) → id`, `updatePlaylist(id, {...})`,
`addSongToPlaylist(playlistId, Song song)`, `reorderSongs(playlistId, oldIndex,
newIndex)`, `getPlaylistSongs(id) → List<Song>`, `isSongInPlaylist(playlistId,
songId) → bool`. Actual (Batch 3) API alag hai:
`createPlaylist(Playlist playlist)` (insert-or-replace, id return nahi karta),
koi `updatePlaylist` hai hi nahi, `addSongToPlaylist(playlistId, String
songId)`, `reorderSongs(playlistId, List<String> orderedSongIds)`,
`getPlaylistSongs(id) → List<String>` (ids, Song objects nahi), aur koi
`isSongInPlaylist` method nahi.
**Filhaal:** Saari 4 screens actual API ke hisaab se likhi gayi hain:
- id `uuid` package se locally generate hoti hai (`create_playlist_screen.dart`)
- "update" ke liye `createPlaylist()` hi same id ke saath dobara call hota hai
  (`ConflictAlgorithm.replace` isse row overwrite kar deta hai)
- "already in playlist" check `playlist.songIds.contains(song.id)` se locally
  hota hai (jo data already load ho chuka hota hai use karke)
**Fix (optional):** Agar future me DB layer ko is prompt ki shape se match
karana ho to `PlaylistDB` me `updatePlaylist()` aur `isSongInPlaylist()`
add kiye ja sakte hain — filhaal zaroorat nahi thi.

### 18. Playlist songs ka data resolve karna — RESOLVED Batch 14B (dekho #33)
**File:** `lib/screens/playlist_detail_screen.dart`
**Issue:** `playlist_songs` table sirf `song_id` store karti hai — title/
artist/thumb/duration nahi, aur koi alag "SongDB" nahi hai jahan se poora
`Song` data kisi bhi id ke against wapas mil jaaye.
**Filhaal:** `_resolveSongs()` helper `LikedDB` + `CacheDB` + `DownloadDB`
teeno ko merge karke ek id→Song pool banata hai, fir playlist ki songIds ko
usse match karta hai. Matlab: agar koi song kabhi bhi like/cache/download
nahi hua (sirf ek baar search result se seedha playlist me add hua tha),
wo playlist detail screen me dikhega nahi — silently skip ho jayega.
**Fix (agar chahiye):** Ek chhoti `SongDB` (ya `playlist_songs` table me hi
title/artist/thumb/duration columns add karke) banani hogi jo har song ka
poora data apne paas rakhe, chahe wo kahin aur liked/cached/downloaded ho
ya na ho.

### 19. `Playlist` model me description/private field nahi hai — RESOLVED Batch 14B (dekho #33)
**File:** `lib/screens/create_playlist_screen.dart`
**Issue:** Batch 11 prompt ne description TextField aur "Private" switch
maange the, lekin `Playlist` model (Batch 3) me sirf `name`, `coverEmoji`,
`coverGradient`, `songIds`, `isCollaborative`, `folderId` hain — koi
`description`/`isPrivate` field nahi.
**Filhaal:** Dono UI me maujood hain (functional switches/textfield) lekin
DB me save nahi hote — screen band karke wapas khol'no pe khali/off mil
jayenge. Collaborative switch ka "share code" bhi sirf UI display hai (random
generate hota hai), DB me save nahi hota.
**Fix (agar chahiye):** `Playlist` model + `playlists` table me
`description TEXT` aur `is_private INTEGER` columns add karne honge
(migration/version bump ke saath).

### 20. `CreatePlaylistScreen` ab playlist id return karti hai (bool nahi) — Batch 11
**File:** `lib/screens/create_playlist_screen.dart`, `add_to_playlist_sheet.dart`
**Note:** Batch 11 prompt ne "SnackBar → Navigator.pop(true)" bola tha, lekin
`add_to_playlist_sheet.dart` ko naya playlist banne ke turant baad usi me
song add karna tha — isliye `Navigator.pop(context, id)` (id ek `String`)
kiya gaya hai, `pop(true)` ki jagah. Agar koi aur jagah se is screen ko
sirf bool result ke liye call kiya jaye to bhi kaam karega (id != null check
truthy jaisa hi behave karta hai).

### 21. Library/Search screens ab naye playlist screens se wired hain — RESOLVED Batch 14A
**Files:** `lib/screens/library_screen.dart`, `lib/screens/search_screen.dart`,
`lib/widgets/song_card.dart`
**Status:** `library_screen.dart` ke Liked Songs card, playlist list items,
aur "Create" button ab real `LikedSongsScreen`/`PlaylistDetailScreen(
playlistId: p.id)`/`CreatePlaylistScreen` par navigate karte hain (dono
playlist actions `.then((_) => _load())` se list refresh bhi karte hain).
`search_screen.dart` ke `SongCard` me ab "add to playlist" action
(`showAddToPlaylistSheet`) wired hai — download icon ki jagah `playlist_add`
icon dikhta hai (search screen me space kam thi, spec ne yahi fallback allow
kiya tha). Isko enable karne ke liye `SongCard` (`widgets/song_card.dart`)
me ek **naya optional param** `onAddToPlaylist` add karna pada (aur
`onDownload` ko required se optional kiya) — jab `onAddToPlaylist` null hota
hai (baaki saari 6 jagah jahan `SongCard` use hoti hai) tab purana download
button bilkul pehle jaisa hi dikhta/kaam karta hai, koi behaviour change
nahi hua wahan. `search_screen.dart` ka purana `_download()` helper hata
diya gaya hai (ab wahan koi call site nahi bacha).

---

### 22. Artist "Follow" button — koi FollowService nahi hai — Batch 12
**File:** `lib/screens/artist_screen.dart`
**Issue:** Spec ne "Follow (outlined kGreen)" button maanga tha, lekin app
me koi followed-artists table/service hi nahi hai (na DB table, na service).
**Filhaal:** Button sirf is screen ke `State` ka local `bool _following`
toggle karta hai — screen band karke wapas kholo to hamesha "Follow" hi
dikhega, kahin persist nahi hota.
**Fix (agar chahiye):** Ek `FollowedArtistsDB` (sqflite table, jaisa
`LikedDB` hai) banani hogi jisme artist name/thumb store ho, aur
`ArtistScreen.initState()` me check karke initial state set karni hogi.

### 23. Cache Manager "Preload next song" — `CacheService` me field nahi hai — Batch 12
**File:** `lib/screens/cache_manager_screen.dart`
**Issue:** Spec ne "Switch: Preload next song" maanga tha, lekin
`CacheService` (Batch 4) me sirf `getLimitBytes/setLimit` aur
`isWifiOnly/setWifiOnly` hain — koi preload-related field/method nahi.
**Filhaal:** Switch ki value seedha `SharedPreferences` key
`cache_preload_next` me save hoti hai (is screen ke andar hi, `CacheService`
ko touch kiye bina). Koi actual preloading logic kahin implement nahi
hui — value sirf UI me store hoti hai, `background_service.dart` isko
abhi read hi nahi karta.
**Fix (agar chahiye):** `CacheService` me `isPreloadNext()/setPreloadNext()`
add karke, aur `background_service.dart` ke queue-advance logic me agle
song ka audio URL pehle se resolve/cache karke, isko wire karna hoga.

### 24. Stats — koi real per-song/per-day tracking engine nahi hai — Batch 12
**Files:** `lib/screens/stats_screen.dart`, `lib/screens/profile_screen.dart`
**Issue:** Spec ne khud bola tha "No actual tracking engine — filhaal UI +
SharedPreferences placeholder", aur sirf 4 keys maangi thi (`played_songs`,
`listened_seconds`, `top_artists`, `streak`) jinka koi writer bhi app me
kahin nahi hai (sab hamesha 0/khaali padhenge jab tak koi future batch
inko likhna shuru na kare).
**Filhaal:**
- "Top Songs"/"Top Artists" real data (`LikedDB` + `CacheDB` ka merged
  pool) se banti hain, lekin per-song "play count" ek deterministic dummy
  number hai (`id.hashCode % 50 + 1`) kyunki koi real play-count store nahi
  hota — session badalne pe bhi same rahega (hash stable hai) lekin ye
  asli listening history nahi hai.
- "Last 7 Days" bar chart ke liye ek extra key `daily_listened_seconds`
  (7 stringified numbers ki list) use ki gayi hai jo original 4-key spec me
  nahi thi — is key ke bina chart sirf flat/zero bars dikhayega.
- Week/Month/Year/All range chips sirf displayed totals ko ek fixed
  multiplier (0.25/1/11/30) se scale karte hain demo ke liye — koi real
  time-window filtering nahi hai (kyunki per-play timestamps store hi nahi
  hote).
- `ProfileScreen` ka "Hours" stat box bhi wahi `listened_seconds` key padhta
  hai jo `StatsScreen` use karti hai — dono sync me hain but dono hi 0 se
  shuru honge jab tak actual tracking na bane.
**Fix (agar chahiye):** Ek real `PlayHistoryDB` (song id, timestamp, duration
played) banani hogi jisse ye saari cheezein (played_songs count, per-song/
per-artist play counts, daily breakdown, time-range filtering) asal data se
compute ho sakein — `background_service.dart` ke andar har play/skip event
pe isme entry likhni hogi.

### 25. Profile "Logout" — koi AuthService/backend nahi hai — Batch 12
**File:** `lib/screens/profile_screen.dart`
**Issue:** Spec ne "Logout button (red outlined, confirm dialog)" maanga
tha, lekin poora app local-only hai (YouTube search + on-device DBs) —
koi login/account/backend system hi nahi hai kisi bhi batch me.
**Filhaal:** Confirm dialog dikhta hai, "Logout" tap karne pe ek SnackBar
("abhi koi account system nahi hai") aata hai — koi asli session/data clear
nahi hota.
**Fix (agar chahiye):** Jab/agar future me koi account system add ho, tab
is button ko uske saath wire karna hoga.

---

### 26. Settings ke kaafi toggles sirf SharedPreferences me hain, kisi service se wired nahi — Batch 13
**File:** `lib/screens/settings_screen.dart`
**Issue:** Spec ne 10 sections me ~25 toggles maange the, lekin inme se
zyadatar ke liye koi backing service/logic app me exist hi nahi karta
(gapless, crossfade, audio quality, auto-play, normalize volume, downloads
wifi-only/auto-cleanup/quality, notif toggles, private session, duck-on-*
wagera).
**Filhaal:** Sab `setting_*` prefix wali keys ke saath SharedPreferences me
save/load hote hain aur UI turant reflect karta hai, lekin koi actual
playback/download/notification behavior in values se change nahi hota
(e.g. "Audio Quality: Low" select karne se stream quality nahi badalti).
**Auto-cache toggle** bhi isi tarah UI-only hai — `background_service.dart`
ka auto-cache-on-play logic (NOTES.md #4) hamesha chalta rahega chahe ye
toggle off ho ya on, kyunki `CacheService` khud is flag ko kabhi check
nahi karta.
**Fix (agar chahiye):** Har feature ke actual service me corresponding
getter/check add karna hoga (e.g. `background_service.dart` me stream URL
quality param, `youtube_service.dart` ke download me quality param,
`notification_service.dart` me per-channel enable check) taaki ye
settings sach me kuch control karein.

### 27. Sleep Timer — Settings aur Full Player me do alag independent timers — Batch 13
**Files:** `lib/screens/settings_screen.dart`, `lib/screens/full_player_screen.dart`
**Issue:** `full_player_screen.dart` (Batch 10) me pehle se ek local
`Timer? _sleepTimer` hai jo sirf us screen ke `State` ke andar rehta hai.
Spec ne Batch 13 Settings me bhi ek alag "Sleep Timer" dialog maanga —
koi shared `SleepTimerService` nahi hai.
**Filhaal:** `settings_screen.dart` ka apna alag local `Timer` hai. Matlab
agar Settings se 30-min timer set kiya aur phir Full Player khola (ya
uska apna timer set kiya), dono timers ek dusre ko cancel nahi karte —
jo bhi pehle fire hoga wahi `audioHandler.pause()` call karega, aur
Settings screen band hone pe (`dispose()`) uska timer cancel ho jayega
(Full Player wala nahi).
**Fix (agar chahiye):** Ek global `SleepTimerService` (singleton
ChangeNotifier, jaisa `CacheService`/`ThemeService`) banana chahiye jisme
ek hi `Timer` rahe, dono screens usi ko read/set karein.

### 28. Clear App Data / Reset App — kaunsi keys "settings" maani jaati hain, ye assumption hai — Batch 13
**File:** `lib/screens/settings_screen.dart`
**Issue:** Spec ne "Clear app data (except settings)" bola tha, lekin
"settings" ki koi formal list/namespace pehle se defined nahi thi kisi
bhi batch me — har service apni khud ki SharedPreferences keys directly
use karti hai (`theme_mode`, `accent_color`, `cache_limit_bytes`,
`bg_*`, `equalizer_settings`, `listened_seconds`, etc.), koi single
`AppSettings` wrapper class nahi hai.
**Filhaal:** "Clear App Data" un keys ko preserve karta hai jo
`setting_` prefix se shuru hoti hain, ya `theme_`/`accent_color`/
`font_scale`/`animation_speed`/`dynamic_colors` (ThemeService ki keys)
hain — baaki sab (cache limit, background settings `bg_*`, equalizer,
stats, search history, liked/download related prefs agar koi ho) clear
ho jaati hain. "Reset App" is se bhi aage jaata hai — poora
SharedPreferences clear + `CacheService.clearAll()`, lekin SQLite DBs
(liked/playlists/downloads/cache metadata) ko touch nahi karta.
**Fix (agar chahiye):** Agar "settings" ka scope alag chahiye (e.g.
background settings ko bhi preserve karna hai), to key list explicitly
redefine karni hogi — ya better, ek central `AppPrefsKeys` class banake
saari services usko use karein taaki namespace clear rahe.

### 29. About screen ka Device info sirf Android ke liye hai — Batch 13
**File:** `lib/screens/about_screen.dart`
**Issue:** `device_info_plus` ka `androidInfo` getter sirf Android pe kaam
karta hai (app poori tarah Android-only hai — `pubspec.yaml` me
`flutter_launcher_icons` bhi `ios: false` hai — isliye ye concern nahi
hai abhi), lekin agar kabhi iOS support add ho to ye code crash karega
(`try/catch` "Unknown" fallback dikha dega, crash nahi hoga, bas galat
info dikhegi).
**Fix (agar chahiye):** Platform check (`Platform.isAndroid`) add karke
iOS pe `iosInfo` use karna hoga.

### 30. `GitHub`/`Report Bug` link launch — external browser dependent — Batch 13
**Files:** `lib/screens/about_screen.dart`, `lib/screens/help_screen.dart`
**Note:** `url_launcher`'s `launchUrl` browser/app install pe depend
karta hai — agar device pe koi browser hi na ho (bahut rare), `launchUrl`
`false` return karta hai aur code us case me link ko SnackBar me dikha
deta hai ("Link copied: ..."). Actual clipboard copy nahi hoti (koi
`Clipboard.setData` call nahi hai) — sirf text SnackBar me show hota
hai, jaisa spec ne khud "SnackBar 'Link copied'" option diya tha.

### 31. Profile screen ka Settings/About action ab real screens par jaata hai — RESOLVED Batch 14A
**File:** `lib/screens/profile_screen.dart`
**Status:** AppBar ka settings icon aur "Settings"/"About" section tiles ab
`Navigator.push` se `SettingsScreen`/`AboutScreen` par jaate hain (purana
`_openPlaceholder()` SnackBar helper hata diya gaya hai).

---

### 32. `SongCard` ka `onDownload` ab optional hai — Batch 14A
**File:** `lib/widgets/song_card.dart`
**Note:** `onAddToPlaylist` (naya optional param, dekho NOTES.md #21) ke
saath consistent rehne ke liye `onDownload` ko bhi `VoidCallback?` (optional)
bana diya gaya hai. Render rule: `onAddToPlaylist` diya ho to `playlist_add`
icon dikhta hai, warna agar `onDownload` diya ho to purana download icon
dikhta hai, dono null hon to koi teesra action icon nahi dikhta. Baaki 6
call sites sab `onDownload` explicitly pass karte hain, isliye unka
behaviour bilkul same raha.

---

### 33. Playlist description + private — ab real DB fields, aur song metadata bhi playlist_songs me — Batch 14B (FIX Part 2, final)
**Files:** `lib/db/playlist_db.dart`, `lib/models/playlist.dart`,
`lib/screens/create_playlist_screen.dart`, `lib/screens/playlist_detail_screen.dart`
**Status:** NOTES #19 (`Playlist` model me description/private field na
hone wala gap) ab resolve ho gaya hai:
- `Playlist` model me `description` (String?) aur `isPrivate` (bool) fields
  add hue — `fromMap`/`toMap`/`copyWith` sab me included.
- `playlists` table me `description TEXT`, `is_private INTEGER DEFAULT 0`
  columns add hue. `playlist_songs` table me `title`, `artist`, `thumb`,
  `duration` columns add hue — taaki har playlist song apna poora metadata
  khud carry kare.
- DB version 1 → 2. `onUpgrade` me har `ALTER TABLE` apne alag try-catch
  me hai (column already-exists jaisi benign errors pe crash nahi hota).
- `PlaylistDB.addSongToPlaylist(playlistId, songId)` ka signature badal
  gaya hai — ab `Song` poora object leta hai (`addSongToPlaylist(playlistId,
  Song song)`), taaki title/artist/thumb/duration turant save ho jaayein.
- `PlaylistDB.getPlaylistSongs()` ab `List<Song>` return karta hai
  (pehle `List<String>` ids tha). Internal `_getSongIdsOnly()` private
  helper add kiya gaya `getAllPlaylists`/`getPlaylist` ke liye (jinhe
  sirf ordered id list chahiye `Playlist.songIds` field bharne ke liye).
- **Purane data fallback:** agar kisi `playlist_songs` row me `title`
  khali hai (batch 14B se pehle add hua tha), `getPlaylistSongs()` us
  song ko Liked/Cache/Download DB se resolve karta hai (jaisa
  `playlist_detail_screen.dart` ka purana `_resolveSongs()` karta tha).
  Agar wahan bhi na mile to silently skip hota hai — same as pehle.
- Naye methods: `updatePlaylist(id, {...})` (sirf non-null fields
  update karta hai), `isSongInPlaylist(playlistId, songId)`, aur
  `setPrivate(id, isPrivate)`.
- `create_playlist_screen.dart`: edit mode me description/private load
  hote hain, save pe edit mode `updatePlaylist()` use karta hai aur
  create mode naya `createPlaylist()` — dono description/isPrivate
  pass karte hain.
- `playlist_detail_screen.dart`: `_resolveSongs()` hata diya gaya —
  `PlaylistDB.getPlaylistSongs()` seedha `List<Song>` deta hai ab, is
  liye fallback logic PlaylistDB ke andar hi chala gaya hai (single
  source of truth). `DownloadDB` import isi wajah se yahan se hata,
  kyunki wo sirf `_resolveSongs()` me use hota tha.

**Scope note (4 files se 5 ho gayi):** `addSongToPlaylist`'s signature
badalne se `lib/screens/add_to_playlist_sheet.dart` compile nahi ho raha
tha (wo purane signature ke saath `widget.song.id` — ek `String` — pass
kar raha tha, jabki naya signature poora `Song` maangta hai). Is file
me sirf 2 lines badli gayi hain (`widget.song.id` → `widget.song`, dono
`addSongToPlaylist` calls me) — koi aur logic/UI touch nahi hui. Ye "Zero
compile errors" rule ke liye zaroori tha; batch spec me is file ka zikr
nahi tha isliye yahan explicitly note kar diya.

---

### 34. `youtube_explode_dart` upgraded 2.0.2 → 3.1.0 (YouTube search/stream fail fix) — Post-Batch-15 Fix
**Files:** `pubspec.yaml`, `lib/services/youtube_service.dart`,
`lib/screens/debug_screen.dart` (naya), `lib/screens/home_screen.dart`,
`android/app/src/main/AndroidManifest.xml` (comment-only)
**Issue:** `youtube_explode_dart: ^2.0.2` (Aug 2023) YouTube ke current API
changes ke saath kaam nahi kar raha tha — Trending/Search dono silently
fail ho rahe the (khali list return, koi error UI pe nahi dikhta tha).
**Fix:** Package `^3.1.0` (latest stable, May 2026) pe upgrade kiya. Iske
saath `YoutubeApiClient.androidSdkless` ko primary client banaya —
library ke PR #371 (Feb 2026) ke mutabik purana `android` client apne
`androidSdkVersion` field ki wajah se YouTube ka PO-Token check trigger
karta hai, jo specifically **audio-only streams** ko 403 deta hai (video
metadata/search kaam karta rehta hai, isliye bug intermittent lagta tha).
Client fallback order ab: `androidSdkless → androidVr → ios → android →
mweb`. `search()`/`getAudioUrl()`/`download()` teeno me `print()` error
logging add ki gayi hai.
**Naya debug tool:** `lib/screens/debug_screen.dart` — Home ke AppBar me
naya bug-report icon se khulta hai, "Test Search" / "Test Audio URL" /
"Test Direct Video" buttons se turant pata chal jaata hai ki search fail
ho raha hai ya sirf audio URL resolve, aur poora exception text dikhata
hai.
**Jaanbujhke NAHI badla:** `just_audio` (0.9.36) aur `audio_session`
(0.1.18) ko latest minor (0.10.x / 0.2.x) pe upgrade nahi kiya — ye
pre-1.0 packages hain jinme minor version breaking hoti hai, aur ye is
bug ka root cause nahi the. `cached_network_image`, `provider`, `sqflite`
bhi as-is chhode — unrelated. Agar future me inhe bhi upgrade karna ho to
alag se dedicated batch me karna, kyunki unke breaking changes ke liye
`audio_focus_service.dart`/`background_service.dart` jaisi files bhi
review karni padengi jo is fix ke scope me nahi thi.
**AndroidManifest.xml:** INTERNET permission already present tha,
`usesCleartextTraffic` jaanbujhke `false` hi rakha (saara YouTube traffic
HTTPS hai) — sirf ek verification comment add kiya, koi functional change
nahi.
**Agar 3.1.0 ke saath bhi fail ho:** `pubspec.yaml` me alternative
recommendation section dekho (README.md ke "YouTube ban ho jaye to" wale
part me) — Invidious/Piped API fallback ya yt-dlp server-based approach.

---

### 35. `android/app/build.gradle` — Gradle 9.x "plugins {} must be first" fix — Post-Batch-15 Fix (follow-up)
**File:** `android/app/build.gradle`
**Issue:** NOTES #34 me Flutter SDK CI pin ko 3.47.1 pe bump karne ki
salaah di gayi thi (path package version conflict fix karne ke liye).
Us bump ke baad build ek step aage jaake fail hone laga — `assembleRelease`
Gradle DSL compile error de raha tha: "only buildscript {}, pluginManagement
{} and other plugins {} script blocks are allowed before plugins {} blocks".
**Root cause:** File ke top pe `local.properties` manually parse karke
`flutterVersionCode`/`flutterVersionName` nikalne wala purana-style code
tha — ye `plugins { }` declarative block se PEHLE likha hua tha. Gradle
ka rule hai ki `plugins {}` block file ka sabse pehla statement hona
chahiye (sirf `buildscript{}`/`pluginManagement{}` hi usse pehle allowed
hain) — modern Flutter template (jo 3.47.1 ke `flutter create` se
generate hota hai) is rule ko strictly enforce karta hai.
**Fix:** Manual `local.properties` parsing hata di — `versionCode`/
`versionName` ab seedhe `flutter.versionCode`/`flutter.versionName` se
aate hain (Flutter Gradle plugin khud expose karta hai, jaisa modern
template me hota hai). Baaki sab (namespace, minSdk 23, Java 17,
coreLibraryDesugaring, applicationId) waisa hi rakha gaya hai.

---

---

### Fixed — "Play tap pe kuch nahi hota / app laggy lagta hai"
**Files:** `lib/services/background_service.dart`, `lib/services/youtube_service.dart`,
`lib/widgets/mini_player.dart`
**Root cause:** `playWithRetry()` sirf `playSong()` ke andar `mediaItem.add(...)`
karta tha, aur `playSong()` tab tak call hi nahi hota jab tak
`YoutubeService.getAudioUrl()` (3 attempts × 5 clients, koi network timeout
nahi) URL resolve na kar de. Is poore gap me `mediaItem` null rehta tha,
isliye mini player screen pe aata hi nahi tha — tap karne ke baad user ko
koi feedback nahi milta tha (na spinner, na kuch), sirf kuch second/minute
baad achanak gaana bajta (ya chup-chaap fail ho jaata). Isi wajah se "click
karne pe kuch hota hi nahi, app lag gaya" jaisa feel aata tha.
**Fix:**
1. `playWithRetry()` ab shuru me hi turant `mediaItem` + ek "loading"
   `playbackState` broadcast karta hai, taaki tap karte hi mini player
   turant dikh jaaye.
2. `YoutubeService.getAudioUrl()` ke har client attempt pe `.timeout(10s)`
   laga diya — pehle ek slow/stuck client poore retry loop ko indefinitely
   atka sakta tha.
3. `mini_player.dart` ab `audioHandler.playbackState` (loading/buffering)
   dekh ke play button ki jagah ek chhota spinner dikhata hai jab tak
   stream URL resolve na ho jaaye.
**Note:** Album art ka "rotating vinyl" (full player screen) jaanbujhke
continuously ghoomta hai jab song play ho raha ho (`rotating_vinyl.dart`)
— agar screenshot me artwork ulta/tedha dikhe to ye bug nahi hai, bas
vinyl mid-spin capture hua hai.

---

### 36. Silent failure jab koi song bilkul resolve na ho — Post-Batch-15 Fix
**Files:** `lib/services/background_service.dart`, `lib/main.dart`
**Issue:** Agar `getAudioUrl()` saare 5 clients × 3 attempts pe fail ho
jaaye (jaisa lambi "Full Album/Mix" compilation videos, ya age/region-
restricted videos ke saath hota hai), `playbackState` ko `error` mark
kar diya jaata tha — lekin `mini_player.dart`/`full_player_screen.dart`
sirf `loading`/`buffering` state dekh ke spinner dikhate hain, `error`
state ke liye koi UI nahi thi. Result: mediaItem pehle se set ho chuka
hota (title/thumb dikh rahe hote), progress bar 0:00/0:00 pe frozen,
play button normal "▶" — user ko lagta "kuch hua hi nahi", jabki app
already give up kar chuka hota.
**Fix:** `SurSathiAudioHandler` me `onError` callback add kiya (sabhi 3
error paths — `playSong`, `playWithRetry` ke 3-attempt-fail, `playFromFile`
— ab isko call karte hain). `main.dart` me global `scaffoldMessengerKey`
add karke `initAudioHandler()` ke baad `audioHandler.onError` ko set kiya
jaata hai jo ek SnackBar dikhata hai. Ab jab bhi koi song resolve na ho
paaye, user ko turant pata chal jaayega ("... play nahi ho paya. Koi aur
gaana try karein.") instead of silent 0:00/0:00.
**Root cause is video, bug fix sirf feedback ka hai:** Ye fix sirf UI
feedback deta hai — agar koi specific video (jaise lambi Mix/compilation
videos) YouTube side se hi audio-only stream expose nahi karti, wo
resolve hona shuru nahi ho jaayega. Uske liye `debug_screen.dart` ka
"Test Audio URL" button use karke exact exception dekha ja sakta hai.

---

### 37. "URL resolve to kaam kar rha hai" par phir bhi gaana nahi bajta — Post-Batch-15 Fix #2 (RESOLVED)
**Files:** `lib/services/youtube_service.dart`, `lib/services/background_service.dart`,
`lib/screens/debug_screen.dart`
**User ne pointed out:** Note #36 ka fix assume karta tha ki "URL resolve
fail" hi asli problem hai. Lekin Debug screen ke "Test Audio URL" se check
karne par URL resolve **successfully** ho raha tha, phir bhi gaana play
nahi ho raha tha.
**Asli root cause (2 alag gaps the):**
1. `getAudioUrl()` sirf itna check karta tha ki `manifest.audioOnly` khali
   nahi hai — matlab youtube_explode_dart ne ek URL *bana* diya. Lekin
   "bana hua" URL aur "CDN se actually fetch ho sakne wala" URL alag cheez
   hain — googlevideo.com wala URL expired signature / throttling / wrong
   client ki wajah se 403 de sakta hai jab use fetch kiya jaaye, chahe wo
   "resolve" (bina fetch kiye) successfully mila ho. Debug screen ka "Test
   Audio URL" bhi yahi (insufficient) check karta tha — isi wajah se wo
   "URL OK" dikhata tha jabki asli playback fail ho rahi thi.
2. Jab `player.setUrl(url)` ke baad actual playback CDN error se fail hoti
   thi (403/network drop), ye error `player.playbackEventStream`'s
   `onError` listener me aata tha — jo sirf `processingState: error` set
   karta tha, **`onError?.call(...)` kabhi nahi karta tha**. Isliye
   `main.dart` ka global SnackBar (Note #36 me add kiya gaya) is specific
   path se kabhi trigger hi nahi hota tha — sirf `playSong()`/`playFromFile()`
   ke synchronous try/catch se hota tha, jo yahan fire hi nahi hua (`setUrl()`
   khud throw nahi karta jab URL syntactically valid ho).
**Fix:**
- `youtube_service.dart` me naya `_verifyPlayable(url)` helper — har
  candidate URL ko ek chhota real range-fetch (`Range: bytes=0-1023`) se
  verify karta hai CDN se 200/206 milta hai ya nahi, `getAudioUrl()` ab
  isko har client ke liye check karta hai (fail ho to agla client try
  karta hai, jaisे pehle `audioOnly.isEmpty` case me hota tha).
- `background_service.dart` ke `playbackEventStream`'s `onError` listener
  me ab `onError?.call(...)` bhi call hota hai (mediaItem ke title ke
  saath), taaki async CDN/stream errors pe bhi SnackBar dikhe — pehle sirf
  processing state silently `error` hoti thi.
- `debug_screen.dart` ka "Test Audio URL" result text update kiya gaya hai
  taaki clear ho ki "URL OK" ab real CDN fetch se verify hua hai, sirf
  resolve se nahi (build marker v3 → v4).

_Har naye batch ke baad, agar koi aisa gap/assumption/limitation aaye,
usko yahin niche add karna — README.md sirf progress status ke liye hai,
ye file un cheezon ke liye jo "kaam kar rahi hai par yahan dhyan do"
category me aati hain._

## #35 — youtube_explode_dart hata ke Piped API laga diya (2026-09-16)

**Kyu:** `youtube_explode_dart` ka approach (5 alag YouTube clients fake
karke try karna, har ek pe timeout + CDN verify) fundamentally hi fragile
tha — YouTube apna internal signature/PO-Token logic thoda sa badle to
poori library break ho jaati thi, aur debugging ke liye har baar "kaunsa
client fail hua" trace karna padta tha. User ne khud request kiya: free,
public, zero-maintenance stable alternative.

**Fix:** Poori YouTube-resolution logic (`lib/services/youtube_service.dart`)
ab **Piped** (`github.com/TeamPiped/Piped`) ke public REST API instances
use karti hai:
- Search → `GET {instance}/search?q=...&filter=music_songs`
- Stream URL → `GET {instance}/streams/{videoId}` → `audioStreams[]`
- 7 public instances hardcoded (`_instances` list) — ek fail ho to agla
  try hota hai (same fallback pattern jo pehle clients ke liye tha)
- `_verifyPlayable()` ka range-fetch check as-is rakha gaya hai (Piped ke
  URLs bhi kabhi-kabhi expired/invalid ho sakte hain)
- `pubspec.yaml` se `youtube_explode_dart` hataya, `http` package add kiya
- `lib/models/song.dart` ka unused `Song.fromYtResult()` (jo `yt.Video`
  type leta tha) hataya
- Debug screen (`debug_screen.dart`) me dono "Test Search" aur "Test Audio
  URL" ab live progress dikhate hain (kaunsa instance try ho raha hai) aur
  "Test Audio URL" ko ab "Test Search" pehle chalane ki zaroorat nahi
  (build marker → `DB-FIX-2026-09-16-piped-v1`)

**Trade-off (important):** Piped public instances khud kabhi down/slow ho
sakte hain (ye bhi third-party free servers hain, Render jaisa hi
kabhi-kabhi unavailability ka risk hai) — lekin 7 independent instances
ka fallback isse kaafi kam karta hai, aur agar zaroorat pade to
`_instances` list me se koi bhi instance add/remove kiya ja sakta hai
(latest list: `github.com/TeamPiped/Piped/wiki/Instances`).

---

### Batch 16 (2026-09-16) — CI build hardening (Gradle/AGP9/R8)

- `android/build.gradle` (root, naya) — `jitpack.io` repo add kiya
  (`newpipeextractor_dart` ki transitive `NewPipeExtractor` dependency
  sirf JitPack pe hosted hai, Maven Central/Google pe nahi)
- `android/gradle.properties` (naya) — `android.r8.proguardAndroidTxt.disallowed=false`.
  `flutter_inappwebview_android` (har released version incl. 1.1.3) abhi
  bhi purana `getDefaultProguardFile('proguard-android.txt')` call karta
  hai jo AGP 9 pe hard-fail karta hai — ye open upstream bug hai
  (flutter_inappwebview#2852, ab tak unfixed). Jab fix release ho jaye,
  ye line hata dena.
- `android/app/build.gradle` — `compileSdk` 35→36 (androidx.browser:1.9.0,
  androidx.core:1.17.0, shared_preferences_android, sqflite_android,
  url_launcher_android sab 36 maangte the)
- `android/app/proguard-rules.pro` (naya) — NewPipeExtractor ke README ke
  apne recommended keep rules (`org.mozilla.javascript`/Rhino ke liye) +
  `-dontwarn java.beans.**` (Rhino ka optional JavaBean introspection
  path Android pe exist hi nahi karta)
- `coreLibraryDesugaring`: plain `desugar_jdk_libs` se `desugar_jdk_libs_nio`
  pe shift kiya — NewPipeExtractor docs ke mutabik minSdk 33 se neeche
  (hamara 23 hai) NIO variant chahiye java.nio.file desugaring ke liye.

**Known future landmine (abhi fix nahi kiya, plugin-authors ka scope):**
Build log warn karta hai ki `device_info_plus`, `newpipeextractor_dart`,
`share_plus` purana-style Kotlin Gradle Plugin (KGP) apply karte hain,
aur **future Flutter versions me ye build hi nahi honge** jab tak
in plugins ke authors "Built-in Kotlin" pe migrate nahi karte. Filhaal
warning hai, error nahi — lekin agar kisi din achanak build fail ho aur
error "Built-in Kotlin"/KGP ka mention kare, ye wahi cheez hai. Fix:
in teeno plugins ko latest version pe check/update karna (ya wait karna
unke fix ka).

---

### Batch 17 (2026-09-16) — Notification controls, play/pause flicker, time-delay, live home feed

**#38 — Notification panel me controls nahi aate (MIUI)**
**File:** `lib/services/background_service.dart`
**Issue:** `AudioServiceConfig.androidStopForegroundOnPause: true` tha —
pause karte hi service foreground se demote ho jaati thi. MIUI jaise
aggressive OEMs isi wajah se notification/control-center media card ko
controls-less (sirf title/artist/progress) kar dete hain.
**Fix:** `androidStopForegroundOnPause: false` — service pause ke baad
bhi foreground me rehti hai, controls hamesha dikhte hain.

**#39 — Play/pause tap pe 1 sec ka icon flicker (mini player)**
**File:** `lib/widgets/mini_player.dart`
**Issue:** Loading-spinner sirf `playbackState.processingState`
(loading/buffering) pe based tha. Resume karte waqt just_audio/ExoPlayer
thodi der ke liye phir se "buffering" report karta hai — chahe audio
turant baj raha ho (`playerStateStream` se `playing: true` already aa
chuka). Isse spinner pause icon ke upar ~1 sec overlay ho jaata tha.
**Fix:** `isLoading` ab `playing` bhi dekhta hai — agar player already
playing hai, buffering-blip ignore hota hai (spinner sirf tab jab abhi
tak playing false hai).

**#40 — Gaana change karne pe time/seekbar me delay**
**File:** `lib/screens/full_player_screen.dart`
**Issue:** Duration/position `StreamBuilder`s bina key ke the, isliye
gaana change hone par (mediaItem turant update hone ke bawajood) purana
cached duration/position dikhate rehte the jab tak naye source ka
`setUrl`/`setFilePath` poora load na ho jaaye.
**Fix:** `ValueKey('duration-${song.id}')` / `ValueKey('position-${song.id}')`
laga diya — gaana badalte hi ye StreamBuilders fresh restart hote hain,
aur `total` ke liye turant `mediaItem.duration` (already known) fallback
milta hai jab tak player khud resolve na kare.

**#41 — YouTube Music jaisa live/curated home feed**
**Files:** `lib/services/youtube_service.dart` (naya `getHomeFeed()` +
`getYtMusicPlaylistTracks()`), `lib/screens/live_playlist_screen.dart`
(naya), `lib/screens/home_screen.dart`
**Kya:** `dart_ytmusic_api`'s `getHomeSections()` use karke home screen
ab YT Music ka live/curated feed dikhata hai ("Trending", "Quick picks"
jaise sections) — har section ya seedhe gaano ki list hota hai ya
curated live playlists ki list (tap karne pe `LivePlaylistScreen` khulti
hai jo tracks `getPlaylistVideos()` se live load karti hai). Agar live
feed khaali aaye (parsing fail/network), purana fixed-query "Trending
Now" fallback ke roop me chalta hai — home screen kabhi khaali nahi
rehti.
**Limitation:** Album-type sections (jaise "New Albums") is version me
skip ho jaate hain — unke liye `getAlbum()` se alag flow chahiye hoga,
abhi implement nahi kiya.
**Test on real device zaroori hai** — home feed ek se zyada network
calls karta hai (search se heavier), CI/GitHub Actions pe test mat karo.

---

### Batch 18 (2026-09-16) — Download reliability fix, mini player download+radio, playlist bulk-download, categorized search, voice search

**#42 — "Download nahi hota" — asli root cause mila aur fix kiya**
**File:** `lib/services/storage_service.dart`
**Root cause:** `getMusicDir()` hamesha hardcoded public path
`/storage/emulated/0/Music/SurSathi` pe seedha likhne ki koshish karta
tha. Manifest me `requestLegacyExternalStorage="true"` hai, lekin ye flag
Android 11+ (API 30+) pe **Android khud ignore kar deta hai** — sirf
Android 10 tak kaam karta hai. Isliye Android 11+ devices pe har download
`FileSystemException` (permission denied) se fail hota tha, chahe
`Permission.storage.request()` "granted" hi kyun na bole (scoped storage
alag cheez hai runtime permission se). `youtube_service.dart`'s
`download()` ka try/catch isko chup-chaap pakad leta tha — sirf generic
"Download fail ho gaya" SnackBar dikhta tha, kabhi asli reason screen pe
nahi aata tha.
**Fix:** `getMusicDir()` ab pehle public `Music/SurSathi` try karta hai
(ek chhota real write-test file banake confirm karta hai ki likha ja
sakta hai, sirf `create()` pe bharosa nahi karta) — agar wo fail ho
(exception), `getExternalStorageDirectory()/Music` (app-specific,
kisi bhi Android version pe bina kisi permission ke likha ja sakta hai)
pe fallback karta hai.
**Trade-off:** App-specific fallback path pe gaye downloads file
manager/other music apps ke "Music" folder me nahi dikhenge (wo
`Android/data/com.sursathi.../files/Music` me honge) — lekin app ki apni
Downloads screen (jo `DownloadDB` se aati hai, disk path se nahi) hamesha
sahi dikhayegi, aur sabse important: download ab actually **succeed**
hoga jahan pehle silently fail ho raha tha.

**#43 — Mini player: download + radio buttons**
**File:** `lib/widgets/mini_player.dart`
**Kya:** Mini player ab `StatelessWidget` se `StatefulWidget` ban gaya
hai (download/radio ke "in progress" spinner ke liye local state
chahiye tha). Do naye compact icon buttons add hue:
- **Download** — jo gaana abhi stream ho raha hai (current `MediaItem`)
  usko seedha yahin se download karta hai (`YoutubeService.download()`),
  pehle check karta hai `DownloadDB.exists()` se ki already download to
  nahi (agar hai to "pehle se downloaded hai" SnackBar).
- **Radio** — naya `YoutubeService.getRadioQueue()` call karke queue me
  similar gaane **add** karta hai (queue replace nahi karta — abhi chal
  raha gaana disturb nahi hota).
**Space constraint:** 70dp height wale row me pehle se heart+play/pause
the — naye buttons 20px icon + 32×32 tap target ke saath compact rakhe
gaye hain taaki row overflow na ho. Chhoti screens pe abhi bhi tight ho
sakta hai — agar overflow dikhe, future batch me heart button ko full
player me move karke mini player se hata sakte hain.

**#44 — Playlist bulk download**
**File:** `lib/screens/playlist_detail_screen.dart`
**Kya:** AppBar me naya download icon (more_vert ke bagal me) —
`_downloadAll()` poori playlist ke saare gaane sequentially download
karta hai, ek non-dismissible progress dialog (`X/N ho gaye · done ·
skipped · failed`) ke saath. Already-downloaded songs (`DownloadDB.exists()`
se check) skip ho jaate hain, dobara download nahi hoti.

**#45 — Search: YouTube Music jaisa Songs/Artists/Playlists tabs**
**Files:** `lib/services/youtube_service.dart`, `lib/screens/search_screen.dart`
**Kya:** Search screen ab search hone ke baad 3 tabs dikhata hai
(`TabBar`/`TabBarView`, `SingleTickerProviderStateMixin`). Songs tab
purana hi hai (`search()`). Artists/Playlists tabs naye `searchArtists()`/
`searchPlaylists()` (`youtube_service.dart`) use karte hain, jo lazy-load
hote hain (sirf jab user pehli baar us tab pe tap kare). Artist tap →
`ArtistScreen(artistName, artistThumb)`, Playlist tap →
`LivePlaylistScreen(playlistId, title, subtitle, thumb)` — dono existing
screens hain, koi naya navigation code nahi likhna pada.
**IMPORTANT ASSUMPTION (test on real device se confirm karna):**
`searchArtists()`/`searchPlaylists()` `dart_ytmusic_api`'s `YTMusic`
client pe call hote hain — package me `searchSongs()` already confirmed
kaam kar raha hai (`getHomeFeed()`/`search()` me use hota hai) usi
jagah se maana gaya hai ki `searchArtists(query)`/`searchPlaylists(query)`
bhi exist karte hain, aur unke result objects ke fields
(`artistId`/`name`/`thumbnails` aur `playlistId`/`name`/`artist.name`/
`thumbnails`) `getHomeFeed()` ke andar already-confirmed `PlaylistDetailed`
handling se match karte hain — isliye confidence high hai, lekin agar
package ka real API thoda alag nikle, dono methods apne try/catch me fail
ho ke sirf khaali list dete hain (us tab me "kuch nahi mila" dikhega) —
Songs tab, home feed, playback, sab kuch is se bilkul unaffected rahega.
Real device pe build karke Artists/Playlists tab test karna zaroori hai.

**#46 — Mic se search (voice search)**
**Files:** `pubspec.yaml` (naya `speech_to_text: ^7.0.0`),
`android/app/src/main/AndroidManifest.xml` (naya `RECORD_AUDIO`
permission), `lib/screens/search_screen.dart`
**Kya:** Search bar me naya mic icon — tap karne pe
`SpeechToText.initialize()` (jo khud runtime mic permission maangta hai)
aur `listen()` shuru hota hai, bolte hi text field me live transcribe
hota hai, aur final result milte hi automatically `_runSearch()` call ho
jaata hai. Agar device pe speech recognition available na ho (`initialize()`
false de), SnackBar dikhta hai — koi crash nahi.

**Repo me push karne ke baad zaroori:** `flutter pub get` (naya
`speech_to_text` dependency ke liye).

---

### Batch 19 (2026-09-16) — Next/previous crash fix + unlimited search scroll

**#47 — "Next par bahut baar tap karo to app crash ho jaata hai" (RESOLVED)**
**File:** `lib/services/background_service.dart`
**Root cause:** `skipToNext()`/`skipToPrevious()` pehle turant har tap pe
`_playCurrentFromQueue()` call karte the, jo turant `playWithRetry()` ->
`YoutubeService.getAudioUrl()` shuru kar deta hai — ismein NewPipeExtractor
(WebView-based JS solver), youtube_explode_dart, aur Piped, teeno heavy
network/native calls hain. `_playToken` sirf ye rokta hai ki PURANA result
final playback-state ko overwrite kare — lekin har tap ka poora resolve
pipeline (WebView spin-up sameet) fir bhi background me chalta rehta hai,
chahe uska result baad me discard ho jaaye. Jab user next ko bahut
jaldi-jaldi (ek ke baad ek) dabata hai, kai saare in-flight
WebView/network extractions ek saath overlap ho jaate hain — MIUI jaise
kam-RAM/aggressive OEMs par ye native crash (OOM ya WebView instance
limit) trigger karta hai, sirf Flutter-side error nahi (isliye koi
catch/onError isko pakad nahi paata tha, aur "next kaam nahi karta" jaisa
symptom bhi isi wajah se aata tha).
**Fix:** `skipToNext()`/`skipToPrevious()` ab turant resolve shuru nahi
karte — sirf `QueueService` ka current index turant update hota hai, aur
asli `_playCurrentFromQueue()` ek chhoti 350ms debounce (`Timer`) ke baad
hi chalta hai. Isse agar user 5 baar jaldi-jaldi next dabaye, sirf EK hi
resolve pipeline shuru hoga (aakhri index ke liye) — beech ke saare taps
sirf debounce timer reset karte hain, koi extra heavy call nahi karte.
`stop()` ab is naye `_skipDebounce` timer ko bhi cancel karta hai.

**#48 — "Search unlimited nahi hai, limited hi gaane aate hain" (RESOLVED,
device pe confirm karna)**
**Files:** `lib/services/youtube_service.dart`, `lib/screens/search_screen.dart`
**Root cause:** `search()` ka Layer 1 (`dart_ytmusic_api`'s `searchSongs()`)
ek single API call hai jiska koi continuation/pagination is wrapper me
expose hi nahi hota — jitne results ek baar me aa jaayein bas utne hi,
dobara wahi call karne pe wahi results wapas aate. Isi wajah se search
list hamesha ek fixed chhoti size pe atak jaati thi, chahe `max` param
jitna bhi bada rakho.
**Fix:** `youtube_explode_dart`'s generic `yt.search.getVideos()` (jo
already Layer 2 fallback me use hota hai) actual me paginated hota hai
(`.nextPage()` se agla page milta hai) — isko naye
`YoutubeService.loadMoreSearchResults(query)` method me "load more"
source banaya hai:
- Pehla page (best-ranked, YT Music curated) ab bhi normal `search()` se
  hi aata hai — koi change nahi.
- `search_screen.dart` ke Songs tab me ab `ScrollController` hai — list
  ke aakhri ~400px reh jaane pe khud-ba-khud agla page load hota hai
  (infinite scroll, jaisa YouTube Music karta hai). Agar results itne
  kam hain ki list scroll hi nahi hoti (chhoti screen), ek post-frame
  check (`_maybeAutoLoadMore()`) khud hi agla page mangwa leta hai.
- Duplicate IDs (jo Layer 1 ke pehle batch me already dikh chuke) naye
  pages se filter ho jaate hain.
- List ke bilkul aakhir me ek chhota marker hai — "Aur gaane nahi bache"
  jab YouTube ke paas sach me is query ke liye kuch bacha na ho, warna
  loading spinner (khud-ba-khud agla page laata hua).
- Naya search (`_runSearch`) hamesha pagination state (`_hasMore`,
  `_loadingMore`) reset karta hai taaki purani query ka "load more" naye
  query me continue na ho.
**IMPORTANT ASSUMPTION (device pe confirm karna):** `getVideos()` ke
return object (jiska exact type-name is codebase me kahin explicitly
likha nahi gaya — existing Layer 2 code bhi sirf type-inference se
use karta hai) par `.nextPage()` method available hone ka assumption
hai (youtube_explode_dart ka well-known pagination pattern). Isko
verify karne ke liye jaanbujhke `dynamic` + per-item try/catch use kiya
gaya hai (dekho NOTES #34/#45 ke jaise assumptions) — agar `.nextPage()`
kisi wajah se na ho ya package ka real behaviour alag nikle,
`loadMoreSearchResults()` bas khaali list de dega (list turant "Aur
gaane nahi bache" pe end ho jayegi, jaise pehle se tha) — koi crash ya
compile error nahi hoga, bas "unlimited scroll" wapas purane fixed-size
jaisa reduce ho jayega. Real device pe scroll karke confirm karna zaroori
hai ki naye pages sach me aa rahe hain.

---

### Batch 20 (2026-09-16) — User re-report: crash on song tap + stale search + limited results (RESOLVED)

User ne khud report kiya ki Batch 19 ke baad bhi (a) ek gaana bajte waqt
koi doosra gaana tap karne pe ~1 sec me crash ho jaata hai, (b) search me
kabhi-kabhi "purana" (galat query ka) result dikhta hai, aur (c) YT Music
search results hamesha ek fixed chhoti size pe atke rehte hain. Teeno ko
reproduce/trace karke, teeno alag root causes nikle (user ka apna "queue
mismatch" wala shak sahi DIRECTION me tha — do requests overlap ho rahi
thi — bas exact mechanism thoda alag tha har case me):

**#49 — Crash sirf "next" tak fix hua tha, har gaane-tap pe nahi**
**File:** `lib/services/background_service.dart`
Batch 19 (#47) ka 350ms debounce sirf `skipToNext()`/`skipToPrevious()`
ke andar tha. Lekin **har** screen (search, home, artist, album, library,
playlists, liked songs, live playlist) jab user kisi bhi song pe tap
karta hai to seedha `audioHandler.playWithRetry(song)` call karti hai —
in sab paths pe koi debounce nahi tha. Root cause bilkul #47 jaisa hi:
`_playToken` sirf stale RESULT ko overwrite hone se rokta hai, lekin
har tap ka heavy resolve pipeline (NewPipeExtractor WebView solver +
youtube_explode_dart + Piped) turant background me shuru ho jaata tha,
chahe result discard hi kyun na ho — rapid taps overlapping native/WebView
calls trigger karte the jo crash deta tha (OOM/WebView-instance-limit,
native-side, isliye koi Dart catch/onError pakad nahi paata).
**Fix:** Debounce ab `playWithRetry()` ke andar hi CENTRALIZED hai (retry-
loop ko naye private `_resolveAndPlay()` me extract kiya gaya) — isse
skip/previous AUR har screen ka seedha tap, dono ek hi jagah se protect
hote hain. `skipToNext()`/`skipToPrevious()` ka apna alag debounce hata
diya gaya (ab zaroorat nahi, `playWithRetry()` khud karta hai) — dono ab
seedha `_playCurrentFromQueue()` ko await karte hain.

**#50 — Search me "purana gana": koi sequence guard nahi tha**
**File:** `lib/screens/search_screen.dart`
`_runSearch()` (chip tap / history tap / voice search / debounced typing
— sabse call hota hai) me koi request-sequence guard nahi tha. Agar do
queries kabhi thodi overlap kar jaayein (e.g. ek chip tap kiya, network
slow nikla, turant dusra chip tap kar diya), aur PEHLI (purani) query ka
response DUSRI (nayi) query ke response ke BAAD aata, to screen pe purani
query ke results reh jaate the — search bar me text kuch aur, list neeche
purani/galat query ki. `_loadMoreResults()` me bhi wahi risk tha (purani
query ka "load more" response naye query ke `_results` me mix ho sakta
tha).
**Fix:** Naya `_searchSeq` int token — har `_runSearch()` call apna unique
seq leta hai, response aane par check hota hai ki ye ab bhi LATEST search
hai ki nahi (`seq != _searchSeq` ho to state touch nahi karta, chup-chaap
discard). `_loadMoreResults()` bhi isी seq ko capture karke same guard
use karta hai.

**#51 — Search "unlimited scroll" (Batch 19 #48) kabhi trigger hi nahi
hota tha kai cases me — asli root cause mila**
**File:** `lib/services/youtube_service.dart`
`_moreSearchQuery`/`_moreSearchContinuation`/`_moreSearchExhausted`
singleton fields the. `search()` me bug tha: `_moreSearchQuery = query`
Layer 0 (`_innertube.searchSongs()`) ke CALL SE PEHLE set hota tha, lekin
`_moreSearchContinuation`/`_moreSearchExhausted` sirf us call ke SUCCESS
hone ke baad hi update hote the. Matlab agar Layer 0 THROW kar jaata
(flaky/early-stage endpoint), `_moreSearchQuery` naye query pe already
set ho chuka hota lekin continuation/exhausted PURANI (kisi bilkul alag
pichhli query ki) value pe reh jaate — `loadMoreSearchResults()` ka
`_moreSearchQuery != query` check galti se "match" maan leta (naam same
hai) aur purani query ka stale exhausted-flag reuse ho jaata — agar
purani query exhausted thi, naya query bhi turant "no more" maan leta,
chahe uske paas khud results bache hon. Isi tarah agar Layer 0 success
hota par `page.items` khaali aata (display Layer 1/2 se hota), tab bhi
continuation Layer 0 ke khaali page se hi set ho jaata — displayed
results se mismatch.
**Fix:** `search()` ab call ki shuruaat me hi teeno field unconditionally
reset karta hai (naya query ke liye, default `exhausted: false` — taaki
Layer 0 fail/khaali ho to bhi `loadMoreSearchResults()` khud apna
fallback try kare, turant "no more" na maan le), aur continuation/
exhausted ko sirf TABHI set karta hai jab Layer 0 ka page.items khud
display ho raha ho — taaki pagination state hamesha wahi reflect kare jo
user ko screen pe dikh raha hai.

**Test on real device:** teeno fix compile-level safe hain (koi naya
dependency/API assumption nahi), lekin #49 (crash) aur #51 (pagination)
dono network-timing-dependent hain — bahut jaldi-jaldi rapid taps se aur
scroll karke confirm karna zaroori hai.

---

### Post-Batch-20 Fix — Real root cause of "gaana badalte hi crash" mila (user ne khud correct kiya: sirf tap se nahi, khatam hone pe bhi)

User ne bataya ki Batch 20 ka #49 fix poora nahi tha — crash sirf rapid-tap
se nahi, ek NORMAL transition se bhi hota hai (gaana khud khatam ho ke agla
bajte waqt bhi). Isse pata chala ki debounce (300ms) sirf REDUCE karta tha
overlap ka CHANCE, ASLI root cause khatam nahi karta tha:

**Asli mechanism:** `_audioViaNewPipe()` (`youtube_service.dart`) ke andar
`npe.VideoExtractor.getStream()` (NewPipeExtractor ka WebView-based JS
solver) ek single call 5-30 second tak le sakta hai. Debounce sirf itna
karta hai ki bahut jaldi-jaldi taps se sirf EK resolve SHURU ho — lekin agar
wo EK resolve abhi bhi chal raha hai (WebView call ke beech mein, await pe)
jab agla NORMAL transition ho (chahe khud khatam hoke auto-next ho, ya ek
click jo debounce window ke BAAD aaya ho), to naya resolve bhi apna khud ka
`npe.VideoExtractor.getStream()` call kar deta hai — do WebView-based native
extractions overlap, aur yahi native crash hai (OOM/WebView instance limit,
MIUI jaise kam-RAM OEMs pe) — bilkul normal ek-ke-baad-ek transitions me bhi
reproduce hota hai, koi rapid double-tap zaroori nahi. Dart try/catch isko
pakad nahi sakta (native process-level crash hai).

**Fix (`youtube_service.dart`):** `_audioViaNewPipe()` ke poore body ko ek
naye `_newPipeLock` (chained-Future mutex) se wrap kiya — ab poore app me
kabhi bhi EK se zyada NewPipeExtractor WebView call parallel nahi chalegi.
Naya call aaye jab pehla chal raha ho, to wo pehle ke poora khatam hone
(chahe uska result baad me discard ho) ka wait karega, TABHI apna WebView
call shuru karega. **Trade-off:** agar user bahut jaldi-jaldi skip kare, har
naya song apni baari ka wait karega (worst-case ~30s pichhle abandoned
resolve ke liye) — thoda slow feel ho sakta hai bahut rapid skipping me,
lekin crash ab kabhi nahi hoga (safety > speed yahan zaroori tradeoff tha,
kyunki native crash ko Dart-side se cancel/catch nahi kiya ja sakta).

**Bonus fix (`background_service.dart`, `skipToNext()`):** Isi debugging ke
dauraan ek related logic bug bhi mila — queue ke AAKHRI gaane par (repeat
OFF), `QueueService.next()` jaanbujhke currentIndex change nahi karta
(comment: "player ruk jayega"), lekin `skipToNext()` hamesha unconditionally
`_playCurrentFromQueue()` call karta tha — jo usi (abhi-khatam) gaane ko
FIR SE resolve karke replay kar deta tha, jo phir khud khatam hoke phir
replay — ek silent infinite "khatam→replay" loop (har cycle apna naya heavy
resolve call ke saath). Ab `skipToNext()` pehle check karta hai ki "aakhri
gaana + repeat off" hai ki nahi — agar hai, seedha `stop()` karta hai,
replay nahi karta.

---

## 2026-09-17 — PoToken (BotGuard) "real fix" — NEW, UNTESTED

**Root cause (confirmed via `sursathi_app_log.txt`):** stream URL milta tha,
`just_audio` setUrl() PASS hota tha, lekin kuch second baad hi ExoPlayer
"Source error" se drop ho jaata tha — classic PoToken-unverified-client
signature (cold-start data chal jaata hai, phir CDN cut kar deta hai).
Poore codebase me kahin bhi PoToken (BotGuard proof-of-origin token) mint
nahi ho raha tha — sirf signature-cipher solving (Deno solver/NewPipe) thi,
jo alag cheez hai.

**Fix:** naya `lib/services/potoken_service.dart` — hidden WebView
(`main.dart` me `_PoTokenHost`) `youtube.com` load karke `bgutils-js`
(CDN se) ke through asli BotGuard Challenge->snapshot->GenerateIT->
WebPoMinter flow chalata hai, session-bound poToken mint karta hai.
`youtube_service.dart` me `_withPoToken()` se ye token har explode-resolved
stream URL (audio-only + muxed) pe `&pot=` param ki tarah attach hota hai,
verify se pehle.

**STATUS: UNTESTED** — is dev environment me na Flutter SDK hai na network
(sandboxed container), isliye compile/live-test nahi ho saka. Fail-soft hai
(mint fail ho to bas pot skip hota hai, purana behavior), isliye worst case
ye hai ki improvement na ho, crash/regression nahi hona chahiye — lekin
pehli real build (CI) ke logs zaroor dekhna:
- Agar Gradle/`flutter pub get` `webview_flutter` resolve/compile na kare
  (naya dependency hai, pehli baar CI pe chalega).
- Debug screen / app log me "PoToken: OK (minted, cached)" ya "PoToken:
  FAILED (...)" dikhna chahiye — FAILED aaye to error text dekh ke aage
  debug karna (CDN block? bgutils-js API surface badal gaya? visitorData
  nahi mila?).
- NewPipeExtractor (native Kotlin) layer isse cover NAHI hota — sirf
  youtube_explode_dart layer par lagा hai. Piped backup layer bhi jaanbujh
  kar chhoda gaya hai (proxy hai, apna alag domain/handling ho sakta hai).

---

## 2026-09-17 (v2) — PoToken fix ka pehla bug (TrustedScriptURL) — FIXED

Real device log (`sursathi_app_log.txt`) se mila: `PoToken mint FAILED:
Failed to set the 'src' property on 'HTMLScriptElement': This document
requires 'TrustedScriptURL' assignment.` — youtube.com ka Trusted Types CSP
`<script>` tag ke `.src` par direct string assignment block kar raha tha.
Fix: `potoken_service.dart` me bgutils-js ko ab `<script src>` ki jagah
`fetch()` + `new Function()` se load karte hain (Trusted Types ka ye
specific sink bypass ho jaata hai). Ye is dev-environment me abhi bhi
COMPILE/LIVE-TEST nahi ho saka — agla real-device log dekhna zaroori hai.
Agar is fix ke baad bhi "PoToken mint FAILED" aaye (jaise CSP `unsafe-eval`
bhi block kare — alag error hoga "EvalError: ... blocks the use of eval"),
to poora WebView-in-youtube.com approach hi reconsider karna padega (jaise
ek neutral/no-CSP page use karna, agar CORS allow kare).

---

## 2026-09-17 (v3) — PoToken fix ka DOOSRA bug (eval bhi CSP-blocked) — FIXED

Real device log se mila: fetch+Function() wala v2 fix bhi fail hua — naya
error: `Evaluating a string as JavaScript violates this document's Trusted
Type assignment requirements.` Matlab: youtube.com ka CSP sirf `<script
src>` nahi, EVAL/Function() bhi poori tarah block karta hai (poore document
pe restriction hai, kisi ek DOM sink pe nahi). Asli youtube.com page ke
andar humari koi bhi arbitrary JS chal hi nahi sakti thi.

**Fix (ATTEMPT #2):** WebView ab asli `youtube.com` load hi nahi karta.
Iske bajaye apna khud ka khaali HTML (`loadHtmlString`) load hota hai,
jiski koi CSP hi nahi hai (isliye eval/Function/script sab chalte hain),
lekin `baseUrl: 'https://www.youtube.com'` diya jaata hai taaki `fetch()`
calls youtube.com-origin maane jaayein (CORS-safe Google APIs ke liye).
Isi wajah se `visitorData` bhi ab `ytcfg` scrape karne ki jagah khud ek
chhota `youtubei/v1/player` fetch call se bootstrap hota hai.

**STATUS: abhi bhi UNTESTED** (is dev-environment me Flutter SDK/network
nahi hai). Agla real-device log dekhna — agar phir bhi fail ho:
- Error "player response me visitorData nahi mila" → matlab visitorData
  bootstrap call khud fail/blocked hui (CORS ya key issue) — is case me
  ek REAL request key/version chahiye hoga, ya alag bootstrap tarika.
- Error jisme "CORS"/"Failed to fetch" ho → matlab `baseUrl` trick is
  WebView/Android version pe kaam nahi kar rahi — poora approach hi
  reconsider karna padega (jaise Dart-side se Create/GenerateIT calls karna
  aur WebView sirf pure-computation VM steps ke liye use karna).
- Agar bgutils-js load ho gaya (`window.BG`/`window.BgUtils` mila) lekin
  aage koi step fail ho, wo error text bhi seedha dikhega — us hisaab se
  next iteration.

## Part 5 (2026-09-17) — Theme toggle, mini-player swipe, Recently Added

- **Theme toggle (dark/light), ab REAL:** `colors.dart` ke `kBg/kBgElev/
  kSurface/kText/kTextDim` pehle hardcoded `const Color` the (poore app me
  sirf dark values) — ab `AppColorTheme.isLight` flag ke hisaab se dark/light
  palette dene wale getters hain. `theme_service.dart` me sync `mode`
  getter + `init()` add kiya. `main.dart` (`SurSathiApp`) ab `Consumer<
  ThemeService>` se wrap hai — mode + system brightness se `isLight` decide
  karta hai, `AppColorTheme.isLight` set karta hai, aur `MaterialApp` ko
  `ValueKey(isLight)` deta hai (toggle pe poora app fresh rebuild hota hai —
  Home pe reset ho jaata hai, trade-off simple/reliable rehne ke liye).
  `app_theme.dart` me naya `AppTheme.light()`. 78+ jagah `const` hataya gaya
  (kBg/kText waghera ab dynamic hain, const-eval nahi ho sakte) — script se
  verified, koi jagah miss nahi hui.
- **Mini-player swipe gestures:** `mini_player.dart` me swipe-up (full
  player khol) pehle se tha; naya `onHorizontalDragEnd` add kiya — left
  swipe = skip next, right swipe = previous (250px/s threshold, accidental
  taps se bachne ke liye).
- **"Recently added" per playlist:** `playlist_db.dart` me naya
  `getRecentlyAddedSongIds()` (added_at DESC). `playlist_detail_screen.dart`
  AppBar me naya ghadi-icon toggle — ON hone par list added_at order me
  dikhti hai (drag-reorder disable ho jaata hai is mode me, "Play All" bhi
  isi order me chalta hai). `_playFrom()` ka signature `int index` se
  `Song` kiya gaya (BUG FIX bhi: pehle index-based tha, "Recently Added"
  order alag hone par galat gaana play hota — ab displayed list ke against
  hi resolve hota hai).

**Abhi bhi baaki (device pe verify karna hai):** poora batch is sandbox me
compile/run nahi ho saka (na Flutter SDK na network) — sabse zyada risk
wala hissa theme const-stripping hai (bahut saari files touch hui), real
build zaroor lena.

---

## 2026-09-17 (v42) — Bug-fixes batch (screenshots se)

1. **Mini player "green-on-green" invisible icon bug — FIXED.** Download-
   done aur radio-on icons `kGreen` color use karte the, lekin mini player
   ka background bhi `kGreen` hai — active hote hi icon ghul (invisible ho)
   jaata tha. Fix: icon color hamesha black, "ON" state ek dark circular
   badge se dikhate hain (`lib/widgets/mini_player.dart`).
2. **Mini player se download button hataya — DONE.** (`_handleDownload`/
   `_downloading` dead code bhi saath mein hataya.)
3. **Home-screen "Categories" (Spotify jaisa dynamic layout) — SCOPE
   NEEDED, abhi nahi kiya.** Bada UI-redesign kaam hai, exact reference/
   layout confirm karna better hoga isse pehle galat direction mein na
   ban jaaye.
4. **Personalized + YouTube/Spotify public-playlist aggregation
   (search + home) — SCOPE NEEDED, abhi nahi kiya.** Spotify ka koi API
   access/keys is project mein nahi hain (naya, bada integration/legal
   scope). "User ke sunne ke hisaab se personalize" ke liye local
   listening-history based recommendation banaya ja sakta hai (bina
   Spotify ke) — agar yahi scope theek hai to batana, alag se banayenge.
5. **Playlist bulk-download lag + speed + Pause All — FIXED.**
   - Speed: `DownloadQueueService` ab serial (1) nahi, 3-parallel worker-
     pool hai.
   - Lag: bulk-add (`live_playlist_screen.dart`, `playlist_detail_screen.
     dart`) ab `enqueueAll()` (ek hi notify) use karta hai — pehle
     per-song loop se 98 baar UI rebuild hota tha.
   - `playlist_detail_screen.dart` ka apna ALAG serial/blocking-dialog
     wala `_downloadAll()` bhi hata ke shared queue pe convert kiya.
   - Downloads screen: ab saare (3 tak) parallel active downloads dikhते
     hain + "Pause All"/"Resume All" button. HONEST LIMITATION: pause
     abhi CHAL RAHE in-flight downloads ko turant cancel nahi karta (koi
     CancelToken plumbing abhi youtube_service.dart mein nahi hai) — sirf
     naye (queue mein pade) downloads ka start rokta hai.
6. **Settings > Appearance clutter — FIXED.** Accent Color / Font Size /
   Animation Speed / Dynamic Colors (jo khud placeholder tha, kaam kuch
   karta nahi tha) hata diye. Sirf "Theme" (Dark/Light/System) bacha hai.
7. **Moods — listening-history-based + daily-refreshing — SCOPE NEEDED,
   abhi nahi kiya.** Isi tarah ka recommendation-engine kaam hai jaisa
   point 4 — dono ko saath plan karna better hoga (overlap hai).

STATUS: 1, 2, 5, 6 is dev-environment mein compile-test nahi ho paaye
(Flutter SDK nahi hai) — CI build ka result/log dekhna. 3, 4, 7 ke liye
scope confirm karne ka wait hai.

---

## 2026-09-17 (v43) — YouTube-based personalization ("YT Music jaisa")

Spotify route band hai (Feb 2026 se "other users' playlists" API access
hi hata diya gaya — dekho chat, code-level nahi, Spotify ki policy hai).
Isliye poora personalization ab sirf YouTube + apni local listening-history
se:

- **NEW `lib/services/daily_mix_service.dart`** — `PlayHistoryDB.
  getTopArtists()` se user ke top-played artists nikaal ke, har ek ke liye
  (uske history mein sabse zyada chale gaane ko "seed" bana ke)
  `YoutubeService.getRadioQueue()` (wahi jo mini-player ke Radio feature
  mein use hota hai) se ek 20-gaane ki "Mix" banata hai. Result din-bhar
  ke liye SharedPreferences mein cache hota hai (roz naya/refresh —
  jaisa Spotify/YT Music ka Daily Mix karta hai). Naya user (history
  khaali) → khaali list, section hi nahi dikhta.
- **NEW `lib/screens/daily_mix_screen.dart`** — ek mix ke gaane
  (smart_playlist_screen.dart jaisa hi layout), "sab download karo"
  button.
- **`home_screen.dart`** — "Your Daily Mixes" horizontal section, search
  bar ke turant baad, Categories se pehle.
- **Note**: "Categories" section (Bollywood/Punjabi/etc, fixed 12-item
  list) abhi bhi static hai — user ka original point 3 (Spotify-style,
  har baar update) uske alawa tha; isko Daily Mix se overlap na ho isliye
  abhi chhoda hai — agar chahiye to alag se scope karenge.
- **Search me sab playlists already aati hain** — `search_screen.dart` ka
  "Playlists" tab pehle se `YoutubeService.searchPlaylists()` use karta
  hai (koi naya kaam nahi karna pada, already tha).

STATUS: is dev-environment mein compile-test nahi ho paaya. `getRadioQueue`
shared state (`_radioSeedId`) ke ek chhote edge-case ke liye
youtube_service.dart mein comment daala hai.

## Part 8 — Radio Mode Phase 3 (2026-09-17)

Implemented `lib/services/radio_engine.dart` as the standalone selection layer:
- hard 150-day non-repeat exclusion via `RadioHistoryStore`
- oldest-history graceful fallback when the candidate pool is exhausted
- approximate equal-weight language balancing
- ~60% hits / ~40% latest bucket preference per language
- popularity + recency + effective mood score + small random jitter
- weighted-random selection (not always top-score)
- 3-5 song look-ahead helper without duplicate IDs

Protected playback/resolve pipeline files were not modified. This phase only
selects candidates; fetching/playing remains the existing app pipeline.

## Part 8 — Radio Mode Phase 4 (2026-09-17)

- Added `lib/screens/radio_language_select_screen.dart`.
- Radio language selection is multi-select; minimum 1 language is required.
- Current radio pool options follow the app's existing music categories: Bollywood, Punjabi, Haryanvi.
- Selected languages persist in `SharedPreferences` under `radio_selected_languages`.
- On load, saved values are filtered against currently supported radio languages, so stale/removed language codes cannot break the screen.
- Selection is also mirrored into `RadioService.instance.selectedLanguages` for the current session.
- `Start Radio` persists the ordered selection and returns it to the caller. Phase 5 will replace this completion step with the actual Radio Player.
- Added a Radio icon to Home's top bar to open the language selector.
- No playback/resolve/CDN/background protected methods were modified.
- No caching/download/prefetch logic was added for Radio Mode.

## Radio Mode — Part 5 (2026-09-17)
- Added `lib/screens/radio_player_screen.dart`.
- Reel-style full-screen Radio Player with vertical swipe gestures.
- Swipe up = skip; skip records history + applies temporary mood decay.
- Swipe down / Previous = one-step navigation back; it does not apply skip penalty.
- Play/Pause uses the existing `audioHandler` only; no playback/resolve pipeline changes.
- Auto-next listens to `just_audio` completion state and selects the next Radio candidate.
- 4-song look-ahead is selected locally from the Part 3 engine; it is metadata only, not audio pre-cache/download.
- Favorite uses existing `LikeService`; favorite tags receive the Radio mood boost.
- Radio candidate loading uses two searches per selected language: relevance/hits + recent uploads.
- Search failure for one language/query is fail-soft; other candidates can still play.
- `RadioLanguageSelectScreen` now transitions into `RadioPlayerScreen` after Start Radio.
- Protected `youtube_service.dart`, `innertube_client.dart`, and protected `background_service.dart` playback methods were not modified.
- Note: the existing global `audioHandler.playWithRetry()` may still honor the app-wide Auto-download-on-Play setting if that setting is enabled; Part 5 does not alter that protected pipeline behavior.

## Part 6 — Smart Local Playback Cache

- Last **15 non-favorite played songs** are retained in the local audio cache.
- The cache is **local-first** for Previous/replay: disk cache is checked before any fresh network resolve.
- When a cached song is played again, its `last_played` timestamp is refreshed so it stays in the 15-song rotation.
- Favorite/liked songs are marked **protected** and are not evicted by the 15-song rotation or normal cache cleanup.
- If a song is liked while it is currently playing, the background cache writer detects the liked state after the file is written and protects that cached file.
- The existing size ceiling remains as a secondary safety limit; protected favorites can remain even when the unprotected rotation is full.
- Cache failures never block playback; network playback continues normally when a local file is unavailable.


## Part 7 — Radio Reset & Change Language

Implemented from the Radio Mode roadmap phase 7.

- Added a top-right ☰ Radio menu with only **Reset & Change Language**.
- Confirmation dialog warns that the Radio session/mood state will reset while saved language selections remain.
- Confirm clears temporary mood state, pauses Radio playback, and returns to the Language Select screen.
- Language Select reloads the persisted selection, so previous choices remain pre-ticked.
- Radio queue/candidate state is discarded by leaving the player; no protected playback/resolve/CDN pipeline was modified.
- Part 6 cache behavior remains intact: recent-play cache and favorite protection are not cleared by Radio reset.

## Part 9 — Radio Mode Entry Icon

- Finalized the Home top-bar Radio entry point as a dedicated `radio_rounded` icon.
- Added explicit accessibility semantics (`Open Radio Mode`) and a tooltip.
- Tapping the icon opens the existing Radio Language Select flow directly; no duplicate Radio session is created at the Home layer.
- Removed the temporary selection-count SnackBar from the entry point so navigation remains clean and immediate.
- No playback/resolve/CDN/background protected pipeline was modified.
- Existing Parts 1–8 behavior, including 15-song local cache and favorite protection, remains unchanged.

## Part 10 — Radio Mode Documentation & Phase Tracking (2026-09-17)

- Completed the final documentation phase from `PART8_RADIO_MODE_ROADMAP.md`.
- Consolidated Radio Mode implementation status through Phases 1–9.
- Documented the Part 6 local-first cache behavior: last 15 non-favorite played songs rotate by LRU; favorite cached songs remain protected.
- Documented the Part 7 reset/change-language behavior, Part 8 fail-soft synced lyrics, and Part 9 Home entry icon.
- No application playback/resolve/CDN code was changed in Part 10; this phase only updates project documentation and status tracking.

## Part 11–12 — Radio tuning and transition hardening (2026-09-17)
- Radio non-repeat window is explicitly fixed at 150 days (5 months), within the original 4–6 month target.
- Mood scores remain session-only by default.
- Previous is one-step history navigation and does not create duplicate Radio history entries.
- Radio Player now serializes auto-next/swipe/Previous transitions with `_transitioning`; fast repeated gestures cannot launch overlapping transitions.
- The transition guard is released in `finally`, including failed playback paths.
- Protected streaming/resolve/CDN/background methods remain unchanged.

## Radio — Post Part 3–12 Bug-Fix Audit (2026-09-17)

- Fixed Radio completion ownership: while `RadioPlayerScreen` is active, the global `AudioHandler` completion listener no longer advances the normal `QueueService`; Radio owns its own auto-next transition.
- Fixed Radio transition subscription lifecycle: the Radio completion listener is cancelled on screen dispose.
- Fixed mood-decay accounting: skip penalties are now stored separately from the base mood score, so even escalated penalties recover exponentially instead of permanently lowering the base score.
- Fixed multi-language eligibility: fresh/fallback selection is evaluated per language, so an exhausted language cannot disappear merely because another selected language still has fresh candidates.
- Improved hits/latest candidate sampling by shuffling within each bucket before applying the approximate 60/40 target.
- Fixed stale cache metadata: when a CacheDB row points to a missing audio file, the stale row is removed during local-cache lookup.
- Existing 15-song recent cache and favorite-protected cache behavior remains intact.
- Protected resolve/CDN pipeline remains unchanged apart from the additive Radio completion-ownership hook.


====================================================================
RADIO BUG-FIX BATCH — 2026-09-17 (SOURCE PATCH AFTER PART 1-12 AUDIT)
====================================================================

Baseline used:
- SurSathi Part 1-12 Bug Audit dated 2026-09-17.
- Flutter/Dart SDK was not available in the audit environment, so this batch
  is source/static verified only; a real flutter analyze/APK/device playback
  run is still required on a Flutter-capable machine.

The requested record format below is: BEFORE -> BUG -> FIX -> AFTER.

[BUG-01] RadioEngine.pickNext() missing
BEFORE: radio_engine.dart called pickNext(), but the method did not exist.
BUG: compile blocker; Radio could not choose first/next candidate.
FIX: implemented pickNext() with eligible-pool build, scoring, jitter and
     weighted-random selection, including excludeIds support.
AFTER: all existing Radio pickNext() call sites now point to a real method.

[BUG-02] Weighted selection pipeline disconnected
BEFORE: helper functions existed, but no pickNext() connected them.
BUG: mood/popularity/recency/language weighting never executed.
FIX: pickNext() now runs the complete pipeline in the intended order.
AFTER: selection is executable and weighted rather than undefined.

[BUG-03] Global oldest IDs used for a per-language fallback
BEFORE: a language used one global oldestPlayedSongIds() list.
BUG: the list could contain other-language IDs and miss older candidates for
      the exhausted language.
FIX: removed the unsafe global fallback path completely. Per-language fresh
     eligibility is evaluated directly.
AFTER: a language can no longer accidentally re-introduce a recently-played
       song from a broken global fallback. The hard 150-day rule wins.

[BUG-04] Fallback could return all recently-played items
BEFORE: when fallback found nothing, code returned `items` wholesale.
BUG: this directly bypassed the hard 150-day non-repeat rule.
FIX: there is now NO fallback to recently-played items.
AFTER: a song inside the 150-day exact-ID exclusion cannot be selected.

[BUG-05] Android/media-control Next/Previous bypassed Radio
BEFORE: background_service.dart always routed media Next/Previous to
        QueueService.
BUG: notification/headset/car buttons used a different navigation system.
FIX: Radio registers onNext/onPrevious callbacks with AudioHandler; media
     controls call those handlers while Radio owns playback.
AFTER: screen swipe, auto-next and Android media controls use one Radio path.

[BUG-06] Leaving Radio could hand completion back to global queue
BEFORE: dispose() released ownership but did not stop Radio playback.
BUG: a still-playing Radio track could later complete under global queue
      ownership.
FIX: dispose() now stops playback and releases Radio ownership safely.
AFTER: leaving Radio cannot leave an orphaned Radio track running.

[BUG-07] Current song updated before playback succeeded
BEFORE: _current changed before await playWithRetry().
BUG: failed resolve/play could leave the UI showing an unplayed/failed song.
FIX: actual playback is awaited first; only then _current and related UI state
     are updated.
AFTER: failed playback no longer poisons current Radio state.

[BUG-08] Loading ended before resolve/play completed
BEFORE: _loading=false was set before playWithRetry().
BUG: UI could look ready while the audio was still resolving.
FIX: loading state is cleared only after playback successfully starts.
AFTER: spinner/ready state follows actual playback start.

[BUG-09] Skip position used wall-clock time
BEFORE: DateTime.now() - _startedAt counted network delay and pause time.
BUG: a 20s listen + 5min pause could record about 320s.
FIX: skipPositionSec now comes from just_audio player.position.
AFTER: skip position tracks actual playback position, not wall clock.

[BUG-10] One skipped song created two history rows
BEFORE: start created wasSkipped=false; skip appended wasSkipped=true.
BUG: duplicated/contradictory events inflated radio_history.
FIX: RadioHistoryStore.markLatestAsSkipped() edits the existing play event.
AFTER: one play session remains one history row, later marked as skipped.

[BUG-11] Auto-cache accepted any HTTP body as audio
BEFORE: request body was piped into .m4a without status/content validation.
BUG: 403/404/HTML/error bodies could become fake audio cache files.
FIX: require successful HTTP status and audio/video/octet-stream content type,
     reject empty/tiny responses, and delete failed partial files.
AFTER: error responses are not registered as valid cache audio.

[BUG-12] Invalid existing cache could recur forever
BEFORE: DB/file existence was checked, but file bytes were never validated.
BUG: a bad-but-existing .m4a row could be retried on every playback.
FIX: CacheDB validates MP4/M4A (`ftyp`) or WebM/EBML headers plus minimum size;
     invalid files are deleted from disk and DB.
AFTER: invalid-but-existing cache rows self-clean when read.

[BUG-13] Prefetch counted as recently played
BEFORE: CacheDB.add() always wrote last_played=now, including background
        prefetches the user never heard.
BUG: fake recent-play entries polluted the 15-song rotation.
FIX: cache insertion now accepts markAsPlayed; prefetch writes no new
     last_played value, while real playback updates it.
AFTER: the 15-song rotation represents played songs, not merely cached ones.

[BUG-14] Favorite protection race on newly cached song
BEFORE: cache was inserted/enforced first, then LikeService protection ran.
BUG: a liked song briefly entered the cache as evictable.
FIX: CacheService checks LikeService BEFORE CacheDB.add() and inserts the
     protected flag atomically with the row; existing protected state is kept.
AFTER: a liked cache entry enters enforcement already protected.

[BUG-15] Duplicate hit/latest result lost latest metadata
BEFORE: one global seen set kept the first hit result and discarded the
        same video's latest result.
BUG: overlap was always classified as hit/non-latest and skewed the mix.
FIX: duplicate IDs are merged; latest flag and strongest soft signals survive.
AFTER: one song can carry both hit and latest evidence.

[BUG-16 / BUG-23] Search rank treated as real popularity
BEFORE: rank was given a large popularity influence.
BUG: search position is not a true view/frequency popularity metric.
FIX: rank remains only a weak hint with a much smaller weight.
AFTER: rank cannot overpower mood, language balance and variety.

[BUG-17 / BUG-22] Latest recency was one fixed constant
BEFORE: every latest candidate had recency=0.85.
BUG: yesterday's result and a near-boundary result scored the same.
FIX: latest results receive a continuous position-based relative-recency hint;
     it is soft and limited, because the current YtResult model does not expose
     an authoritative publication timestamp.
AFTER: latest ordering has internal variation instead of one fixed value.

[BUG-18] Language balancing depended on missing pickNext()
BEFORE: _languageWeight() existed but could not be executed.
BUG: approximate language balancing was effectively dead.
FIX: pickNext() now applies a small target-share correction per language.
AFTER: selected languages influence the weighted pick without a rigid lock.

[BUG-19] Tagging false positives from substring matching
BEFORE: `contains(keyword)` could match inside unrelated larger words.
BUG: short keywords such as `dil`, `ram`, `high`, `night` could over-tag.
FIX: keyword/phrase matching now normalizes punctuation and matches complete
     tokens/phrases.
AFTER: accidental substring tags are reduced while multi-word keywords remain
       supported.

[BUG-20] Fixed 60/40 hit/latest pool did not match natural-mix requirement
BEFORE: _applyBucketPreference() physically cut candidates into ~60/40 pools.
BUG: eligible songs were removed before final scoring, making the order ruley.
FIX: hard bucket filtering was removed. Popularity/recency/latest are soft
     score hints across the full eligible pool.
AFTER: old/new/hit/latest can naturally vary (no repeating 60/40 pattern).

[BUG-21] "Old" release age must not mean low priority
BEFORE: bucket logic implicitly treated hit/latest membership as the main pool
        decision.
BUG: release age and last-played age were being conflated.
FIX: release/newness is only a soft score input; the 150-day last-played rule
     remains the only hard repeat filter.
AFTER: an old song not played for 150+ days can compete normally, subject to
       soft mood/popularity/recency signals.

[BUG-24] Randomness applied after fixed filtering instead of after scoring
BEFORE: pool was cut first, then shuffled/selected.
BUG: early filtering reduced variety before weighting could act.
FIX: order is now: eligible pool -> mood/language/soft type signals -> small
     random jitter -> weighted random pick.
AFTER: randomness changes the choice naturally without bypassing eligibility.

[NON-BUG CHECKS KEPT]
- Radio completion listener cancellation on dispose remains present.
- Global completion suppression while Radio owns playback remains present.
- Mood penalty remains separate from base score.
- Radio transition guard/finally release remains present.
- Protected resolve/CDN pipeline methods were not redesigned.

[VERIFICATION STATUS]
- Source/static patch: completed.
- Flutter/Dart build/analyze: NOT RUN in this environment because SDK is not
  installed here.
- Real Android notification/headset/device playback test: still required.
- Cache header validation is intentionally conservative; if a future provider
  returns a different container format, the cache validator should be extended
  rather than accepting arbitrary HTML/error bodies.


# v53 Radio Bug Fix Update (2026-09-17)

Existing notes above are unchanged. This section records the implementation target from the Part 1–12 audit.

## Fixed bugs
- BUG-01 to BUG-05: Radio selection engine, language-aware fallback, hard 150-day non-repeat, media controls.
- BUG-06 to BUG-10: Radio ownership, playback state, loading, skip timing, duplicate history.
- BUG-11 to BUG-14: Cache validation, corrupt cache cleanup, prefetch vs played tracking, favorite protection.
- BUG-15 to BUG-24: Natural old/new/hit/latest weighted mix, soft popularity & recency scoring, tagging improvements.

Format preserved: previous notes were not edited; only this new section was appended.


# v55 Radio Enhanced

This section was appended without changing any previous NOTES.md content.

## Fixed / implemented

- BUG-25 — Radio artwork was inset by SafeArea and could leave black edges.
  Previous behavior: the full player background lived inside SafeArea and used a raw Image.network, causing edge gaps and visible loading flashes.
  New behavior: artwork is a full-screen edge-to-edge layer; Radio content alone respects SafeArea, and artwork changes use a 300ms AnimatedSwitcher fade with warmed image providers.
  Files modified: lib/screens/radio_player_screen.dart

- BUG-26 — Radio screen UI could lag behind the audio/notification identity.
  Previous behavior: `_current` was assigned only after playback succeeded, while the media notification could already contain the new song.
  New behavior: one candidate generation commits current artwork/title/artist/like state/lyrics reset/progress identity together before starting the candidate; stale lyric/like results are rejected by the same generation token.
  Files modified: lib/screens/radio_player_screen.dart, lib/services/background_service.dart

- BUG-27 — Timeline was missing a real player-driven seek bar.
  Previous behavior: Radio showed no current-vs-total player timeline.
  New behavior: a draggable timeline reads `just_audio` position/duration, renders smooth frame-driven progress, and seeks the actual player without wall-clock calculation.
  Files modified: lib/screens/radio_player_screen.dart

- BUG-28 — Lyrics were a two-line switcher, not synchronized scrolling LRC.
  Previous behavior: only the current and next lyric were shown and the active line did not auto-center.
  New behavior: parsed LRC lines scroll smoothly, active line is bright/bold/glowing, inactive lines are smaller/faded, and unavailable synced lyrics show `No synced lyrics available` without collapsing layout.
  Files modified: lib/screens/radio_player_screen.dart, lib/services/lyrics_service.dart

- BUG-29 — Completed Radio playback could stop instead of advancing cleanly.
  Previous behavior: completion depended on the screen transition timing and the shared background completion path.
  New behavior: Radio retains playback ownership, completion immediately advances through the Radio candidate path, and the background handler never delegates Radio completion to QueueService.
  Files modified: lib/screens/radio_player_screen.dart, lib/services/background_service.dart

- BUG-30 — Resolve/play failures could surface repeated user-facing errors.
  Previous behavior: Radio shared the normal global playback error path, so failed candidates could repeatedly surface retry/error UI.
  New behavior: Radio errors route to an invisible session recovery callback: after a failure, wait 2 seconds, retry automatically up to 8 times, then mark the song failed for the session and skip it without repeated dialogs.
  Files modified: lib/screens/radio_player_screen.dart, lib/services/background_service.dart, lib/services/radio_engine.dart

- BUG-31 — Stream-drop recovery used QueueService's current song even during Radio.
  Previous behavior: background stream-drop handling read `QueueService.instance.currentSong`, which is not authoritative while Radio owns playback.
  New behavior: the background handler tracks the active playback Song independently and uses the Radio error callback when Radio owns playback.
  Files modified: lib/services/background_service.dart

- BUG-32 — Radio preload depth was too small and was tied to queue preloading.
  Previous behavior: Radio kept only four upcoming candidates and background prefetching was designed around QueueService.
  New behavior: Radio keeps up to ten candidates ahead; the next ten artworks and lyrics metadata are prefetched with bounded concurrency, while only the next two Radio songs receive audio resolve/cache preload through a Radio-only handler API that never mutates QueueService.
  Files modified: lib/screens/radio_player_screen.dart, lib/services/background_service.dart, lib/services/lyrics_service.dart

- BUG-33 — Radio selection did not explicitly remember session-failed candidates or liked weighting in one engine-owned session state.
  Previous behavior: exclusion was passed ad hoc by the screen and liked status was checked only for the visible song.
  New behavior: RadioEngine owns a session failed-ID set and liked-ID set; failed candidates are hard blocked, likes receive a weighted boost only, and the engine keeps hard 150-day exclusion plus mood, skip-derived mood penalty, language balance, soft old/new signals and randomness.
  Files modified: lib/services/radio_engine.dart, lib/screens/radio_player_screen.dart

- BUG-34 — Media/headset next/previous needed an explicit Radio error/ownership boundary.
  Previous behavior: Radio had next/previous ownership but no separate Radio error boundary.
  New behavior: next/previous remain routed to the Radio screen while owned, and playback failures are routed to the same Radio recovery path; QueueService is not taken over.
  Files modified: lib/services/background_service.dart, lib/screens/radio_player_screen.dart

## Files modified in v55

- lib/screens/radio_player_screen.dart
- lib/services/radio_engine.dart
- lib/services/background_service.dart
- lib/services/lyrics_service.dart
- NOTES.md (append-only)

`audio_handler.dart`, `lib/widgets/radio_lyrics.dart`, and `lib/widgets/player_progress.dart` were not created or renamed because those files do not exist in the supplied v54 project; the existing architecture keeps the audio handler in `background_service.dart` and the Radio UI in `radio_player_screen.dart`.

# v55 Radio UX Hotfix — 2026-09-17

This section is appended only; all earlier NOTES.md content remains unchanged.

## BUG-35 — Synced lyrics blocked Radio swipe/skip interaction
- Previous behavior: the large lyrics ListView participated in the vertical
  gesture arena while the whole player also listened for vertical swipes. This
  could consume the gesture and make Radio skip/previous feel unresponsive.
- New behavior: Radio no longer uses swipe navigation at all, and the lyrics
  surface is non-interactive. Skip is an explicit next-song button, so lyrics
  can never block playback controls.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-36 — Previous button and swipe hint made the Radio controls confusing
- Previous behavior: the player showed a previous button plus "Swipe up = Skip /
  Swipe down = Previous", even though gesture handling could conflict with
  synchronized lyrics.
- New behavior: the on-screen previous button and swipe hint are removed. A
  dedicated next/skip button is shown beside the play button. Headset/media
  previous remains available through the Radio ownership handler.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-37 — Timeline and play controls were too high on the screen
- Previous behavior: lyrics, timeline, controls and the swipe hint were stacked
  as a normal scrolling column, pushing the main controls around on different
  screen sizes.
- New behavior: title/artist stay slightly below the top bar, synchronized
  lyrics occupy flexible middle space, and the real player timeline plus play
  and like/next controls stay anchored toward the bottom inside SafeArea.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-38 — Reopening Radio always behaved like a fresh session
- Previous behavior: tapping Radio from Home always opened language selection,
  even after the user had already chosen languages.
- New behavior: language selection is shown only when no Radio languages have
  been saved. Later Radio taps open the Radio player directly with the saved
  language set.
- Files modified: lib/screens/home_screen.dart

## BUG-39 — Radio did not resume the last cached Radio song
- Previous behavior: reopening Radio started candidate discovery again, so the
  user could see a fresh loading/buffering period instead of returning to the
  last Radio track.
- New behavior: the last Radio song identity is persisted. On the next Radio
  open it is attempted first, allowing background_service to use its existing
  disk/in-memory cache before falling back to normal Radio discovery. The last
  song is not duplicated into Radio history merely because Radio was reopened.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-40 — Lyrics panel was visually oversized for a music-player layout
- Previous behavior: the synchronized lyrics view consumed a fixed 220px area
  and pushed the timeline/controls downward.
- New behavior: lyrics are presented as a compact centered synchronized panel,
  with a smaller active line and reduced inactive-line scale/opacity, leaving
  the bottom controls and timeline accessible on compact phones.
- Files modified: lib/screens/radio_player_screen.dart

## Verification
- Dart/Flutter SDK is not installed in this build environment, so `flutter
  analyze` / Android build could not be executed here.
- Dart delimiter/static source checks passed for the modified Radio/Home files.
- Project package name, directory structure and existing assets were preserved.

# v55.1 Radio Sync + Lyrics Reliability Hotfix — 2026-09-17

This section is appended only; all earlier NOTES.md content remains unchanged.

## BUG-41 — Lyrics were effectively single-provider dependent
- Previous behavior: Radio lyrics depended on LRCLIB alone and cached a negative/empty result, so many Indian catalogue songs could remain without lyrics.
- New behavior: synced LRC is still preferred from LRCLIB, with additional LRCLIB matching by title/artist, then JioSaavn's India catalogue lyrics endpoint and lyrics.ovh as plain-lyrics fallbacks. Temporary provider failures are not cached as permanent "no lyrics" results.
- Important: plain lyrics are never given fake timestamps. The UI explicitly marks them as available but not synchronized.
- Files modified: lib/services/lyrics_service.dart

## BUG-42 — Lyrics loading could visually dominate the player
- Previous behavior: the lyrics area could look like a blocking loading panel and did not distinguish synced lyrics from plain fallback lyrics.
- New behavior: synced lyrics use a compact centered karaoke presentation with active-line glow, scale/opacity changes and automatic centering. Plain fallback lyrics remain readable in a non-blocking scroll area.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-43 — Play/Pause did not clearly communicate buffering
- Previous behavior: the main play control could continue showing a normal play/pause glyph while just_audio was loading or buffering.
- New behavior: the main control follows just_audio's PlayerState. During loading/buffering it becomes a dedicated animated progress indicator and cannot accidentally start a second playback request.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-44 — Timeline could rebuild continuously while paused
- Previous behavior: a permanent frame ticker called setState even when the player was paused.
- New behavior: position/duration streams are the primary timeline source; the frame ticker only fills visual interpolation while audio is actually playing. Seeking still calls just_audio directly.
- Files modified: lib/screens/radio_player_screen.dart

## BUG-45 — Notification buffering state needed to stay tied to the real player
- Previous behavior: Radio UI buffering state and notification state could be interpreted separately.
- New behavior: the existing background audio handler continues publishing just_audio loading/buffering/ready states through AudioService playbackState. The Radio UI now uses the same just_audio PlayerState for its visible buffering indicator, keeping the notification and main control state aligned without introducing a second playback state machine.
- Files modified: lib/screens/radio_player_screen.dart (existing background_service state bridge retained; no QueueService takeover)

## Verification
- Project package name and directory structure preserved.
- Existing assets preserved.
- NOTES.md appended only.
- Dart source delimiter/lexical-balance checks pass for modified files.
- Flutter SDK is not installed in this build environment, so a device/Gradle build could not be executed here.


# v55.2 Adaptive Radio Recommendation — 2026-09-17

## RADIO-ADAPT-01 — Behaviour-based recommendation learning
- Previous behavior: Radio primarily used mood scores, likes, language balance,
  search popularity/recency and randomness. A listener who repeatedly completed
  or quickly skipped songs without pressing Like had limited influence on future
  selections.
- New behavior: Radio now learns from persisted Radio playback history. Full or
  near-complete listens provide positive signals; early skips provide negative
  signals. These signals softly influence song/tag, artist and language affinity.
- The adaptive layer is deliberately bounded so it cannot overpower the existing
  language, mood, freshness and weighted-random behavior.
- Unseen artists/tags receive a small exploration bonus to prevent an overly
  narrow recommendation loop.

## RADIO-ADAPT-02 — Richer playback history
- Radio history now stores artist and duration in addition to the existing song,
  language, tags, timestamp and skip position.
- Existing history remains backward compatible: old entries without artist or
  duration load with safe empty/zero defaults.
- On a skip, the existing history entry is updated with the actual skip position,
  allowing the recommender to distinguish an early skip from a song skipped near
  completion.

## RADIO-ADAPT-03 — Like + behaviour signals work together
- Explicit Likes remain a strong soft boost with their existing cooldown behavior.
- Listening behavior is now an independent signal, so Radio can learn even when
  the user never taps Like.
- The hard 150-day exact-song repeat exclusion and session failed-song exclusion
  remain unchanged.

## Modified files
- lib/services/radio_engine.dart
- lib/services/radio_history_store.dart
- lib/screens/radio_player_screen.dart

## Compatibility
- Existing package name, project structure, navigation, theme and assets are
  preserved.
- NOTES.md was append-only.
- No database migration is required because Radio history is JSON in
  SharedPreferences and the new fields are optional/backward-compatible.

## Verification
- Source-level delimiter/lexical checks were run after the update.
- Flutter SDK/Android Gradle build is not available in this environment, so a
  device APK build could not be performed here.

---

## 2026-09-17 (v64) — Playback state machine (Phase 1)

User ne ek proper state-machine architecture maanga (jaisa production
media apps ka common/well-known pattern hota hai — resolving/verifying/
buffering/playing/error/retrying, ek single source-of-truth, cancellation
via generation-token).

**Note (honesty):** Spotify/YT Music/Apple Music ka EXACT internal code
kahin publicly nahi hai — humne unka code copy nahi kiya, balki wahi
general/industry-standard media-player architecture apnayi hai jo har
achha player use karta hai.

**Kya mila (achi khabar):** is codebase mein already `_playToken`
(generation-counter cancellation) ka sahi mechanism tha — bas har jagah
scattered ad-hoc checks ke roop mein, koi observable STATE nahi.

**Kiya (Phase 1 — foundation, poora rewrite nahi):**
- `background_service.dart` me naya `enum PlaybackPhase` (idle, resolving,
  verifying, buffering, playing, paused, retrying, error) + `ValueNotifier
  <PlaybackPhase> phase` + `ValueNotifier<String?> phaseMessage`.
- `_setPhase(token, phase, [message])` — wahi purana `_playToken` guard
  reuse karta hai (stale request phase overwrite nahi kar sakta).
- Existing transition points (`_resolveAndPlay`, `_playSong`, retry-loop,
  play()/pause() overrides) ab is phase ko set karte hain.
- `mini_player.dart` ab is phase ko dikhata hai — jab gaana "playing" nahi
  hai (resolving/retry/buffering/error), artist ki jagah live status text
  dikhta hai ("Resolving...", "Retry 2/3...", "Playback error").

**ABHI NAHI kiya (bade scope, agla phase):**
- Seekbar/buttons ka poora dedicated per-state UI (abhi sirf ek text
  label hai, poore alag button-sets/animations nahi).
- Notification (Android) khud is naye phase ko separately show nahi
  karti — abhi bhi purane `playbackState.processingState` pe hi hai.
- Cancellation abhi bhi `_playToken` int-based hai, koi formal
  `CancellationToken`/`Completer`-object class nahi bana (kaam karta hai,
  bas "clean-code" angle se ek aur upgrade ho sakta hai agar chahiye).

STATUS: is dev-environment mein compile-test nahi ho paaya.

---

## 2026-09-17 (v65) — Playback state machine (Phase 2 — notification + UI)

Phase 1 (v64) ka follow-up — ab poori tarah wired hai:

- **Notification/lock-screen**: `_setPhase()` ab resolving/retrying/
  buffering/error ke dauraan `MediaItem.artist` ko status-message se
  temporarily replace karta hai ("Resolving...", "Retry 2/3...", "Stream
  URL nahi mila") — Android notification ki subtitle line seedha
  `MediaItem.artist` se aati hai, isliye ab wahan bhi live status dikhta
  hai. `playing`/`paused` hote hi asli artist wapas aa jaata hai.
- **Full player screen**: BONUS — koi extra code likhne ki zaroorat nahi
  padi. `full_player_screen.dart` ka title/artist text pehle se live
  `mediaItem` stream se aata hai (`_songFromMediaItem`), isliye upar wala
  notification-fix automatically wahan bhi phase-status dikhata hai.
- **Retry button (error state) + loading-ring (buffering)**: ye dono
  already pehle se the (`processingState == error/loading` pe based) —
  naye phase-system se conflict nahi karte, dono saath kaam karte hain.

**Honest trade-off note**: `MediaItem.artist` ko status-message se
overwrite karna matlab agar koi code exactly usi 1-2 second window mein
`_songFromMediaItem()` se asli artist nikaalne ki koshish kare (jaise
radio start), to usse temporarily "Resolving..." jaisa text mil sakta
hai, asli artist nahi. Real playback (`_activePlaybackSong`) is se
UNAFFECTED hai — sirf DISPLAY ke liye hai. Risk bahut chhota/rare hai.

STATUS: is dev-environment mein compile-test nahi ho paaya — agla real
build/log dekhna.

---

## 2026-09-17 (v66) — Edge-case fix (proper) + prefetch 2→3 songs

**1. Playback-phase edge-case — PROPERLY fixed (v65 ka patch nahi, root
fix):** v65 mein `MediaItem.artist` ko temporarily status-message se
overwrite kiya jaata tha (resolving/retrying/error ke dauraan). Dikkat:
`.artist` field HI wo jagah hai jahan se app ke andar har jagah "asli
artist" nikala jaata hai — us transient window mein koi bhi consumer
(radio-seed, `_songFromMediaItem()`) galti se status-text ko "artist"
samajh sakta tha.

Root fix: `artist` field ab **KABHI nahi chhua jaata** — hamesha asli
artist. Status message ab `MediaItem.album` field mein jaata hai (jo is
app mein kahin aur use hi nahi hoti thi, bilkul khaali/unused thi) —
`_toMediaItem(song, statusOverride: message)`. Isse:
- Notification: album field se status dikhta hai (**honest note**: album
  line kitni prominently dikhti hai ye Android version/OEM pe depend
  karta hai — kuch devices collapsed view mein nahi, sirf expanded/lock-
  screen mein dikhate hain).
- `full_player_screen.dart`: pehle (v65) ye ACCIDENTALLY artist-hijack pe
  depend karke status dikhata tha (implicit/fragile) — ab explicitly
  `audioHandler.phase`/`phaseMessage` use karta hai (`mini_player.dart`
  jaisa hi pattern) — dono jagah ab consistent aur robust.
- Koi bhi consumer jo kabhi bhi `.artist` padhega, use ab hamesha 100%
  sahi/asli value milegi — koi race/edge-case nahi bacha.

**2. Prefetch 2→3 songs:** `_prefetchNext()` ab agle 3 upcoming gaane
disk pe cache karta hai (pehle 2 the) — smoother skip/next, kam chance
ki koi upcoming gaana bina-cache ke mile. `_urlCache` ka eviction-cap
5→6 (taaki 3 fresh-prefetched entries comfortably fit karein, premature
evict na ho).

STATUS: is dev-environment mein compile-test nahi ho paaya.

---

## 2026-09-17 (v67) — Radio: haan, same kaam already hua tha (+1 gap fix)

User pooch rahe the "radio mein bhi kiya?" — jawab:

- **Prefetch**: Radio ka apna ALAG (aur pehle se BEHTAR) prefetch tha —
  `prefetchRadioSongs()` already 5 gaane aage tak cache karta hai (normal
  queue abhi 3 tak gayi hai). Radio yahan kuch fix karne ki zaroorat
  nahi thi.
- **PlaybackPhase state machine**: Radio bhi seedha `audioHandler.
  playWithRetry()` hi call karta hai (`radio_player_screen.dart` ke
  `_playWithRecovery`/`_ensureRecovery`) — isliye resolving/retrying/
  buffering/error phases automatically radio pe bhi fire hote hain, koi
  alag kaam nahi karna pada.
- **GAP jo mila aur fix kiya**: `radio_player_screen.dart` ka apna ALAG
  UI/layout hai (full_player_screen.dart reuse nahi karta), isliye uska
  apna artist-`Text` widget tha jo phase-status nahi dikhata tha (v65/v66
  ka fix sirf full_player_screen.dart + mini_player.dart tak pahuncha
  tha). Ab explicitly wire kiya — radio screen bhi "Resolving...",
  "Retry...", "Playback error" dikhata hai.

STATUS: is dev-environment mein compile-test nahi ho paaya.

---

## 2026-09-17 (v68) — Radio: 3 real bugs fixed + swipe gesture

1. **Play/pause button "ghumta hi rehta hai" — ROOT CAUSE mila aur FIXED.**
   `_loading = true` set hota tha jab bhi koi candidate try hota, lekin
   FAILURE path mein kahin bhi wapas `false` nahi hota tha:
   - `_playCandidate()` ke fail-branch mein (isse `_previous()` — jo sirf
     EK hi candidate try karta hai, koi retry-loop nahi — sabse zyada
     directly is bug ko trigger karta tha: ek fail hua "Previous" tap =
     permanent spinning button).
   - `_advance()` ke 12-attempt loop ke pura exhaust ho jaane ke case mein
     bhi same gap tha.
   Dono jagah ab `_loading=false` explicitly set hota hai fail hone par.
2. **"Button se karta hoon to instant nahi hai" — FIXED.** `_playCandidate()`
   mein do blocking `await` the jo asli playback se related nahi the:
   `LikeService.isLiked()` (playback shuru hone se PEHLE await hota tha)
   aur `RadioHistoryStore.record()` (jiski wajah se `_transitioning=false`
   — jo Next/Prev button ka spinner control karta hai — audio already
   bajne ke baad bhi der tak true rehta tha). Dono ab non-blocking
   (`unawaited`) hain — audio jitni jaldi actually bajta hai, button
   utni hi jaldi normal dikhta hai.
3. **"Slide se next/previous kaam nahi karta" — ADD kiya (missing tha,
   bug nahi, feature hi nahi thi).** Ab left/right horizontal swipe se
   bhi Next/Previous chalta hai — SCOPE JAAN-BOOJH KAR sirf title/
   artwork/lyrics area tak rakha (seekbar/buttons area ke bahar), taaki
   seekbar ka apna drag-to-scrub gesture kabhi conflict na kare.
4. **"Fast play/cache" — ALREADY tha, kuch naya nahi karna pada.**
   Confirm kiya: Radio `playWithRetry()` ke through hi seedha `_playSong`
   (`useChunking: true` — SPEED FIX) use karta hai, aur `prefetchRadioSongs()`
   already agle 5 gaane disk pe cache kar deta hai (normal queue se bhi
   zyada) — ye sab pehle se sahi tha.

STATUS: is dev-environment mein compile-test nahi ho paaya — khaaskar
swipe-gesture ka scoping (Expanded ke andar GestureDetector) real device
pe zaroor test karna, layout-wise koi chhota gap na aaye.
