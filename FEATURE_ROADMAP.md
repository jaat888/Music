# SurSathi — Feature Roadmap (Baad me karna, abhi ka build fix ho jaye pehle)

Ye file un features ki list hai jo discuss hui (OpenTune/InnerTune jaisi
app dekh ke) aur SurSathi me add karni hain. Pehle current CI build
(gradle/proguard/jitpack) stable karo, phir yaha se ek-ek karke pick karo.

Status legend: `[ ]` not started · `[~]` partially possible with existing
deps · `[!]` needs new dependency or native code

---

## PART 6 — Engagement (DONE, code-level — 2026-09-17)

- **Stats/Streak (real, ab dummy nahi):** `stats_screen.dart` pehle poori
  tarah SharedPreferences placeholder counters + `id.hashCode`-based fake
  per-song play-count pe thi (koi asli tracking nahi, dekho purana
  top-comment). Ab `PlayHistoryDB` (Part 3 ki `play_history` table) me
  naye methods (`totalPlays`, `totalListenedSeconds`, `currentStreakDays`,
  `getTopArtists`, `last7DaysCounts`) se sab REAL hai — total plays,
  listened hours (duration-sum approximation, per-play elapsed time track
  nahi hoti), current streak (consecutive din, `played_at` se compute),
  top artists, aur last-7-days chart (ab asli calendar dates + weekday
  labels, "Mon..Sun" fixed order ka guess nahi). Range chips (Week/Month/
  Year/All) ab asli `played_at` cutoff se filter karte hain.
  `profile_screen.dart` ka "Hours" stat bhi isi real number pe switch kiya
  (pehle wahi dummy `listened_seconds` SharedPreferences key thi).
- **Gamification badges:** 4 simple milestone badges (🔥 7-Day Streak, ⚡
  30-Day Streak, 💯 100 Songs, 🎧 500 Songs) — StatsScreen ke "Badges"
  section me, locked/unlocked purely real `totalPlays`/`streak` values se.
- **Mood-based auto playlist:** naya `lib/screens/mood_playlist_screen.dart`
  — 5 mood chips (Chill/Workout/Party/Sad/Focus). Tap karne pe pehle apni
  library (liked+cache+download pool) me se title/artist keyword-match
  (jaise "lofi"/"chill"/"workout"/"sad") se gaane chunta hai; agar 15 se
  kam milein to `YoutubeService.search()` se online supplement karta hai
  (radio mode jaisa hi fallback pattern) — koi audio-feature/mood-analysis
  nahi hai, sirf keyword heuristic + online fallback jab library khaali
  ho. Library screen ke "Smart" section me "Moods" entry se access.

**Jaanbujhke NAHI kiya:** per-play elapsed listening TIME track karna
(sirf "play shuru hua" record hota hai, poori duration ko approximation
maan ke sum karte hain) — real listening-time tracking ke liye
`background_service.dart` ke andar progress-tick pe likhna padega, jo
scope se bahar rakha gaya taaki playback path (jo pehle se hi bahut
sensitive raha hai is conversation me) bilkul untouched rahe.

**Abhi bhi baaki (device pe verify karna hai):**
- Streak calculation sirf recent 3000 `play_history` rows dekhta hai
  (poori table GROUP BY na karke, bade libraries pe mehenga hoga) — bahut
  purani/gap-wali history pe edge case ho sakta hai, par streak vaise bhi
  ek gap pe reset ho jaata hai isliye practically theek hona chahiye.
- Mood keyword lists heuristic hain (title/artist text-match) — genuinely
  achhe results ke liye real audio-mood-detection chahiye hoga, jo scope
  se bahar hai. Naye/khaali library pe har mood zyada tar online-search
  wale results dikhayega.

**Priority:** Done (code) — ab test/verify karna hai.

---

## PART 4 — Backup/restore (DONE, code-level — 2026-09-17)

- **Export:** naya `lib/services/backup_service.dart` — Liked songs +
  Playlists (poore songs samet, `PlaylistDB.getPlaylistSongs()` se) ko ek
  JSON file me likhta hai (`getTemporaryDirectory()` me), phir
  `share_plus`'s `Share.shareXFiles()` se share-sheet khulti hai (WhatsApp/
  Drive/Files, kuch bhi) — bilkul `debug_screen.dart` ke crash/app-log
  share jaisa hi pattern.
- **Import:** naya `file_picker` dependency (pehli baar — pehle app me
  koi file-choose mechanism nahi tha, sirf outgoing share tha) — user
  `.json` file chunta hai, ek preview dialog (kitni playlists/songs/likes
  hain) confirm karne ke baad `BackupService.importFromFile()` chalta hai.
  **Merge semantics, destructive nahi:** existing liked/playlists delete
  nahi hote — backup wala data upar add/overwrite hota hai (`LikedDB.add`
  aur `PlaylistDB.createPlaylist`/`addSongToPlaylist` dono
  `ConflictAlgorithm.replace` use karte hain, isliye same id dobara
  import karna bhi safe/idempotent hai).
- **UI:** naya `lib/screens/backup_restore_screen.dart`.
  `settings_screen.dart` ke ADVANCED section ke purane "Backup"/"Restore"
  stub tiles (jo sirf ek SnackBar dikhate the, koi asli kaam nahi karte
  the) ab isi screen par navigate karte hain.
- **Scope (jaanbujhke NAHI shamil):** downloaded/cached audio FILES khud
  backup me nahi jaate (sirf list/metadata — id/title/artist/thumb/
  duration) — naye phone pe songs dobara stream/download honge, jaisa
  Part 4 ke ask ("Playlists+likes ko JSON") ne khud scope kiya tha. Play
  history (Part 3) bhi jaanbujhke shamil nahi hai — wo per-device stat
  hai, migrate karne layak "list" data nahi.

**Abhi bhi baaki (device pe verify karna hai):**
- `file_picker` is session me compile/run nahi ho saka (sandbox me
  Flutter SDK/network nahi hai) — `flutter pub get` + real device pe
  "Choose Backup File" test karna zaroori hai.
- Bahut badi library (sainkdo playlists) pe import sequential
  (`await` loop, ek-ek playlist/song) hai — koi batch-insert optimization
  nahi hai abhi, chhoti/medium libraries ke liye fine hai.

**Priority:** Done (code) — ab test/verify karna hai.

---

## PART 3 — Library smarts (DONE, code-level — 2026-09-17)

- **Recently Played (real, dekho NOTES.md #14):** naya `PlayHistoryDB`
  (`lib/db/play_history_db.dart`, `play_history` table) — har successful
  playback start (`background_service.dart` ke teeno play-success paths:
  stream, local-first cache/download, `playFromFile`) ek fire-and-forget
  row insert karta hai. `lib/screens/recently_played_screen.dart` isi se
  "sabse recent play per song" list dikhata hai, "Clear history" ke saath.
- **Duplicate-song detector:** `lib/screens/duplicate_songs_screen.dart` —
  Liked+Cache+Download ka merged pool leke title (brackets/"official
  video"/"lyrics" jaisa clutter hata ke) + artist normalize karke group
  karta hai. 1 se zyada wale groups "duplicate" hain — har copy ko alag-alag
  hata sakte ho (jahan-jahan wo copy hai — liked/cache/download + disk file
  — sab se ek saath remove hoti hai).
- **Smart auto-playlists:** naya `lib/screens/smart_playlist_screen.dart`
  (ek hi generic screen, `SmartPlaylistMode` enum se teeno handle karta
  hai):
  - **Most Played** — `PlayHistoryDB.getMostPlayed()` (asli COUNT(*), koi
    dummy hash nahi).
  - **Never Played** — library pool (liked+cache+download) minus
    `PlayHistoryDB.getPlayedIds()`.
  - **Downloaded Only** — seedha `DownloadDB.getAll()`.
- **Library screen:** naya "Smart" section (Downloads/Playlists ke neeche)
  — Recently Played, Most Played, Never Played, Downloaded Only, Find
  Duplicates, sab yahin se ek tap me khulte hain.

**Jaanbujhke NAHI badla:** streaming/resolve pipeline
(`_resolveAndPlay`/`_playSong`/CDN headers) ko bilkul touch nahi kiya —
sirf `player.play()` safal hone ke BAAD ek additive
`PlayHistoryDB.recordPlay()` call add kiya gaya hai (fire-and-forget, khud
kabhi throw nahi karta), jaisa NOTES.md ke top warning me maanga gaya tha.
Notification-icon fix wali 3 files (`androidNotificationIcon`,
`ic_notification.xml`, `keep.xml`) bhi touch nahi hui.

**Abhi bhi baaki (device pe verify karna hai):**
- Duplicate-detector ka title-normalize regex ek heuristic hai — kuch
  genuinely-different songs (same title, different artist ka cover) ko
  bhi group kar sakta hai agar dono ka normalized title+artist match ho
  jaaye. User ko har group manually confirm karna chahiye delete se pehle
  (isliye per-copy delete hai, "delete all duplicates" jaisa bulk-action
  jaanbujhke nahi diya).
- `play_history` table kabhi clear nahi hoti khud (sirf Recently Played
  screen ke "Clear history" button se) — lambe time use ke baad table
  size grow karegi, koi auto-trim/cap abhi nahi hai.

**Priority:** Done (code) — ab test/verify karna hai.

---


## PART 2 — Sleep timer & EQ (DONE, code-level — 2026-09-17)

- **Sleep timer — "Song khatam hone tak":** naya `SleepTimerService`
  (`lib/services/sleep_timer_service.dart`, global singleton) — pehle
  `full_player_screen.dart` aur `settings_screen.dart` dono ke apne-apne
  ALAG screen-local `Timer` the, jo screen `dispose()` hote hi (matlab
  sleep timer laga ke wapas home pe aane par) chup-chaap cancel ho jaate
  the. Ab dono screens isi ek global service ko use karte hain — kisi bhi
  screen se set/cancel karo, dusri screen turant sahi state dikhati hai,
  aur navigate karne se timer cancel nahi hota. Naya mode: "Song khatam
  hone tak" — current gaana khatam hote hi (agle gaane pe skip kiye
  bina) playback pause ho jaata hai; ye `background_service.dart` ke
  andar hi (`sleepAtEndOfTrack` flag) handle hota hai, isliye UI se
  bilkul independent/reliable hai.
- **Equalizer presets (Bass/Vocal boost — ab REAL hai):** pehle
  `equalizer_screen.dart` sirf ek UI mockup tha — presets/bands sirf
  SharedPreferences me save hote the, koi audio effect kabhi attach hi
  nahi hua tha (dekho purana top-comment). Ab `AndroidEqualizer`
  (just_audio ka ExoPlayer-native EQ) player ke `AudioPipeline` me attach
  hai — preset select karo ya slider hilao, turant asli audio pe apply
  hota hai. UI ke 10 fixed conceptual bands (`equalizer_presets.dart`)
  ko runtime pe device ke asli EQ bands (jo alag ho sakte hain) pe
  log-frequency interpolation se map kiya jaata hai. Settings app restart
  pe bhi restore hoti hain (`_restoreSavedAudioSettings()`).

**Abhi bhi baaki (device pe verify karna hai — sandbox me build/run nahi
ho saka):**
- Real device pe sunke confirm karo Bass/Vocal preset sunai deta hai
  (kuch cheap/old Android OEMs pe `AndroidEqualizer` bilkul available hi
  nahi hota — us case me code gracefully catch karke ignore karta hai,
  silently no-op, koi crash nahi, par EQ bhi kaam nahi karega).
  `AndroidEqualizerParameters`/`AndroidEqualizerBand` API `just_audio`
  0.9.x me jaisa yaad hai waisa hi hai ki nahi, ye bhi build karke hi
  pata chalega.
- "Bass Boost %" / "3D Surround" / "Reverb" sliders (equalizer_screen.dart
  ke neeche wale extra controls) abhi bhi cosmetic/SharedPreferences-only
  hain — sirf 10-band EQ (jisme Bass/Vocal presets hain) real hai. In
  teeno ko real DSP se jodna alag, bada kaam hoga (Android me in effects
  ke liye seedha `just_audio`/`AndroidEqualizer` API nahi hai).
- Sleep timer "Song khatam hone tak" ka ek edge case: agar repeat mode
  "one" ya "all" on hai to `ProcessingState.completed` alag tareeke se
  fire ho sakta hai (just_audio khud loop kar sakta hai) — device pe
  teeno repeat modes ke saath test karna baaki hai.

**Priority:** Done (code) — ab test/verify karna hai, jaisa Part 1 me bhi
hota hai.

---

## PART 1 — Playback controls (DONE, code-level — 2026-09-17)

Sab kuch pehle sirf settings_screen.dart me UI/SharedPreferences state tha,
koi service kabhi read hi nahi karti thi (dekho purana top-comment: "kai
toggle yahan sirf UI/SharedPreferences state hain"). Ab char cheezein
actually kaam karti hain:

- **Playback speed (0.5x–2x):** `SurSathiAudioHandler.setSpeed()` ab
  override + implement hai (pehle sirf `BaseAudioHandler` ka default
  no-op tha) — `player.setSpeed()` call karta hai, `setting_playback_speed`
  me persist karta hai, aur app restart pe wapas apply hota hai
  (`_restoreSavedAudioSettings()`). UI: `full_player_screen.dart` ke chip
  row me naya speed icon (0.5x/0.75x/1x/1.25x/1.5x/1.75x/2x dialog).
- **Audio quality (data saver Low/Med/High):** `youtube_service.dart` me
  naya `_orderByQuality()` — NewPipeExtractor (native Kotlin,
  `NewPipeAudioChannel.kt` ab `quality` arg leta hai aur bitrate ke hisaab
  se sahi stream chunta hai), youtube_explode aur Piped backup, teeno
  layers ab `setting_audio_quality` (streaming) / `setting_download_quality`
  (download, alag setting) padh ke us tier ko PEHLE try karte hain — agar
  wo tier fail ho jaaye to poori list pe fallback hota hai (robustness
  wahi purani hai, sirf order badalta hai).
- **WiFi-only downloads:** `YoutubeService.download()` ab `connectivity_plus`
  se check karta hai (`isDownloadAllowedByNetworkPolicy()`) — `setting_
  downloads_wifi_only` ON ho aur mobile data pe ho to download start hi
  nahi hota (silently `null` return, jaisa baaki resolve-fail cases karte
  hain).
- **Volume normalize:** `just_audio` ka `AndroidLoudnessEnhancer`
  (`AudioPipeline` ke through `player` me attach) — settings switch ab
  `audioHandler.setNormalizeVolume()` bhi call karta hai. **NOTE:** ye ek
  fixed target-gain boost hai (quiet gaano thoda upar), asli per-song
  LUFS/ReplayGain-jaisa loudness-matching NAHI hai — us level ka analysis
  bahut zyada scope hoga. Android-only (package limitation), par app me
  sirf android/ folder hai isliye theek hai.

**Abhi bhi baaki (device pe verify karna hai — is batch me build/run nahi
kiya ja saka, sandbox me na Flutter toolchain hai na network):**
- `flutter pub get` + actual build/run karke confirm karo koi compile error
  nahi (`AndroidLoudnessEnhancer`/`AudioPipeline` API just_audio 0.9.36 me
  jaisa yaad hai waisa hi hai ki nahi, `setSpeed()` override signature
  `audio_service` 0.18.18 ke `AudioHandler` se match karta hai ki nahi).
- Kotlin side (`NewPipeAudioChannel.kt`) ka naya quality-based selection
  compile + real device pe test (khaas kar "low" quality actually chhota
  audio-only stream deta hai ki nahi — kuch videos pe sirf 1-2 hi bitrate
  options hote hain, us case me "low"/"high" same ho sakte hain, ye normal
  hai).
- Normalize Volume ka target gain (`0.5`) ek starting guess hai — real
  gaano pe sunke tune karna padega (bahut zyada boost = loud gaano
  clip/distort karenge).
- Playback speed UI sirf `full_player_screen.dart` me hai, `mini_player.dart`
  me nahi (scope choti rakhi — full player se hamesha access ho sakta hai).

**Priority:** Done (code) — ab test/verify karna hai, jaisa baaki batches me
hota hai.

---

## 1. Live/updated playlist aur search (YouTube Music "innertube" style)

**DONE (2026-09-16, v18):** apna khud ka Dart innertube client bana diya —
dekho `lib/services/innertube_client.dart` (`InnertubeClient`, WEB_REMIX
music.youtube.com endpoint, proper `continuation` token pagination).
`youtube_service.dart` me `search()`, `searchArtists()`, `searchPlaylists()`,
`getYtMusicPlaylistTracks()` aur `loadMoreSearchResults()` — sab ab isko
Layer 0 (pehla try) bana ke use karte hain; `dart_ytmusic_api` /
`youtube_explode_dart` fallback ki tarah waisi hi rehti hain, koi hataya
nahi. `newpipeextractor_dart` abhi bhi sirf stream-URL-resolve ke liye hai —
wo is change se untouched hai.

**Abhi bhi baaki:** device pe real test karna (yeh sirf code-level change
hai, YouTube ke internal JSON shape/params/key kabhi bhi change ho sakte
hain — is case me automatically fallback layers pe chala jaayega, par
"innertube layer khud kaam kar raha hai ya nahi" ye sirf phone pe search
karke pata chalega). Agar `_filterArtists`/`_filterPlaylists` params galat
nikle to sirf wo tabs fallback pe girenge, Songs search alag se test karo.

**Priority:** Done — ab test/verify karna hai.

---

## 1b. Radio mode — unlimited (same InnertubeClient ka istemaal)

**DONE (2026-09-16, v19):** `getRadioQueue()` pehle sirf approximation tha
(current gaane ke artist se `search()` karke shuffle, fixed ~15 gaano ka
ek-baari batch). Ab `InnertubeClient.radioQueue()` use karta hai — YT Music
ka asli "Start radio" endpoint (`next` + `playlistId: RDAMVM<videoId>`),
jisme continuation token milta hai.

`QueueService` me naya `enableRadioMode(supplier)` — jab radio on hai aur
queue ke aakhri 3 gaane reh jaate hain, khud-ba-khud
`YoutubeService.loadMoreRadioQueue()` (usi continuation se agla batch) call
karke queue me jod deta hai. Radio button dabane pe (`full_player_screen.dart`
+ `mini_player.dart`) ab yahi enable hota hai. `setQueue()`/`clear()` radio
mode ko automatically off kar dete hain (album/playlist play karne pe
purana radio carry-forward na ho).

**Limitation:** agar innertube radio fail ho (0 results) to purana
artist-shuffle fallback chalta hai, par wo "unlimited" nahi hai (loadMore
khaali dega) — is case me radio ek fixed batch ke baad ruk jaayega, jaisa
pehle hota tha. Device pe test karke pata chalega asli continuation kitni
der tak chalta hai.

---

## 2. Home screen widget

**Kya milega:** Home screen pe chhota player card — art, title,
play/pause/next/prev.

**Karna kya hoga:**
- [!] `home_widget` package pubspec me add karo (Dart ↔ native Android bridge)
- [!] Native side: Android `AppWidgetProvider` (ya Glance) + widget layout
      XML likhna hoga — pure Dart se nahi banega
- [ ] Jab bhi song change ho / play-pause ho, `home_widget` ke through
      current song info (title, artist, artwork, state) native widget ko
      bhejo
- [ ] Widget tap → app open; buttons → background service ko control
      commands

**Priority:** Medium. Effort: native Android code likhna padega
(OpenTune jitna animated/polished nahi hoga turant, basic functional
widget target rakho).

---

## 3. Baaki discussed features (OpenTune se inspired)

### Easy — mostly existing deps (`just_audio`/`audio_service`) se possible
- [~] Skip silence
- [~] Audio normalization
- [~] Tempo/pitch control
- [~] Gapless/queue playback (already kaafi had tak hai)

### Medium — thoda extra kaam/package chahiye
- [ ] Synchronized lyrics (LRC parsing + koi lyrics API/source)
- [ ] Offline download / on-device local music playback (MediaStore scan;
      `permission_handler` already hai)
- [ ] Dynamic Material 3 theme (`dynamic_color` package)
- [ ] Multi-language (base `intl` already hai, bas translations add karni
      hain)

### Hard — native-heavy ya bahut effort
- [ ] Android Auto support (Flutter me straightforward nahi)
- [ ] Discord Rich Presence (niche, low priority)
- [ ] Dynamic "Canvas" animated artist backgrounds (Apple Music/Tidal
      style) — bahut heavy feature, sabse aakhri me sochna
- [ ] YT Music account login/sync

---

## Reminder

Koi bhi feature start karne se pehle `NOTES.md` (GPL-3.0 licensing
warning) zaroor dekh lena — `newpipeextractor_dart` rakhte hue app
closed-source distribute nahi ho sakti.
