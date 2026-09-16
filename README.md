# SurSathi — Flutter Music App — Progress Notes

Ye file naye Claude instance (ya khud future-me main) ke liye hai — taaki
context na khone pe bhi kaam wahi se continue ho jahan se chhoda tha.

## Project info
- Naam: SurSathi (Hindi/Haryanvi/Punjabi music player, YouTube-based)
- Repo: github.com/jaat888/SurSathi (private)
- Platform: Android APK via GitHub Actions
- User phone se kaam karta hai — PC nahi hai, seedha GitHub pe push hota hai
- State management: Provider
- Flutter SDK: 3.19.0

## Workflow rules (STRICT — follow karna)
- Ek message = ek batch (4-6 files)
- Har file ka POORA code, koi "..." ya "same as before" nahi
- Zero compile errors, real working code (dummy nahi)
- Hinglish comments, short aur kaam ki
- Har file ke top pe path comment: `// lib/theme/colors.dart`
- Batch complete hone pe likhna: "Batch X complete. 'next' bolo Batch X+1 ke liye."
- User "next" bolega tab hi agla batch

## Colors (exact — inhi values ko use karo)
```
kBg        = Color(0xFF0A1428)
kBgElev    = Color(0xFF142850)
kSurface   = Color(0xFF1E3A5F)
kGreen     = Color(0xFF1DB954)
kBlue      = Color(0xFF1E90FF)
kPurple    = Color(0xFF7C6CF0)
kText      = Colors.white
kTextDim   = Color(0xFFA0B0C8)
kRed       = Color(0xFFFF6B81)
```

## Fonts
- Display: Sora (700-800) — headers, logo
- Body: Inter (400-600) — baaki sab
- google_fonts ^6.1.0

## Dependencies (pubspec me already hain)
provider, just_audio, audio_service, audio_session, youtube_explode_dart,
sqflite, path, path_provider, shared_preferences, google_fonts,
cached_network_image, shimmer, permission_handler, device_info_plus,
connectivity_plus, share_plus, url_launcher, intl, uuid,
flutter_local_notifications (added in Batch 5), flutter_launcher_icons (dev)

## Backend files (separate — Claude inke baare me kuch nahi karega)
- `lib/youtube_service.dart` — already working, user khud daalega
- `lib/audio_handler.dart` — already working, user khud daalega
- Batch 5 me jo stub audio handler hai, wo inhi se replace hoga

## STATUS — ab tak kya complete hua

### ✅ Batch 1 — Setup (COMPLETE)
- `pubspec.yaml`
- `android/app/src/main/AndroidManifest.xml`
- `analysis_options.yaml`

### ✅ Batch 2 — Theme + Root (COMPLETE)
- `lib/main.dart` — SystemChrome + AudioService.init stub + MaterialApp;
  `screens/splash_screen.dart` ka import likha hai (file Batch 8 me banegi)
- `lib/theme/colors.dart`
- `lib/theme/app_theme.dart`
- `lib/theme/typography.dart`

### ✅ Batch 3 — Models + DB (COMPLETE)
- `lib/models/song.dart` — fromJson/toJson/fromMap/toMap/fromYtResult/copyWith
- `lib/models/playlist.dart` — fromMap/toMap/copyWith
- `lib/db/liked_db.dart` — singleton, table `liked`
- `lib/db/cache_db.dart` — singleton, table `cache`
- `lib/db/playlist_db.dart` — singleton, tables `playlists` + `playlist_songs`
- `lib/db/download_db.dart` — singleton, table `downloads`
- Sab ek hi DB file use karte hain: `sursathi.db` (version 1)

### ✅ Batch 4 — Services (core) (COMPLETE)
- `lib/services/cache_service.dart` — singleton ChangeNotifier, 2GB default limit, LRU eviction via `CacheDB.getOldestUnprotected()`, liked songs never deleted
- `lib/services/like_service.dart` — singleton ChangeNotifier, toggle liked + marks/unmarks `protected` flag in CacheDB, haptic feedback on toggle
- `lib/services/storage_service.dart` — static helpers: Music/SurSathi dir, cache dir, sanitizeFileName, formatBytes. NOTE: `getFreeSpaceBytes()` returns -1 (no disk-space plugin in deps yet — flagged in code comment, needs a plugin like disk_space/storage_info_plus in a future batch if real value needed)
- `lib/services/theme_service.dart` — singleton ChangeNotifier, theme mode/accent(AccentOption enum: green/blue/purple/pink/orange)/font scale/animation speed/dynamic colors, all via SharedPreferences
- `lib/services/queue_service.dart` — singleton ChangeNotifier, queue state only (no player control — that's Batch 5), shuffle/repeat (RepeatMode enum: off/all/one), next/previous/jumpTo
- `lib/services/search_history.dart` — singleton ChangeNotifier, SharedPreferences JSON list, max 20, dedupe+move-to-top

### ✅ Batch 5 — Audio + Background (COMPLETE)
- `lib/services/youtube_service.dart` — search/getPlaylist/getAudioUrl (5-client fallback)/download (Music/SurSathi/, registers in DownloadDB)
- `lib/services/audio_focus_service.dart` — AudioSession config, interruption (pause/duck) + becomingNoisy (headphone unplug) callbacks
- `lib/services/notification_service.dart` — flutter_local_notifications, 2 channels (sursathi_audio, sursathi_general)
- `lib/services/background_service.dart` — **SurSathiAudioHandler** (BaseAudioHandler + SeekHandler), just_audio integration, play/pause/seek/stop/skip, shuffle/repeat sync with QueueService, playSong/playWithRetry/playFromFile, auto-cache on stream play (fire-and-forget)
- `lib/main.dart` — UPDATED: stub handler removed, real `initAudioHandler()` call, full Provider setup (CacheService/LikeService/ThemeService/QueueService/SearchHistory), AudioFocusService wired to audioHandler
- `pubspec.yaml` — UPDATED: added `flutter_local_notifications: ^17.2.1` (was missing, needed by notification_service.dart)

See `NOTES.md` (in this same zip) for known gaps/assumptions from this batch.

### ✅ Batch 6 — Widgets (core) (COMPLETE)
- `lib/widgets/song_card.dart` — reusable song row (thumbnail+hero, title/artist/duration, play/download/like buttons, cached green dot)
- `lib/widgets/category_card.dart` — stagger entrance (TweenAnimationBuilder) + press-scale (AnimatedScale), gradient alternates by index
- `lib/widgets/section_header.dart` — title + optional "See all"
- `lib/widgets/equalizer_bars.dart` — 3 animated bars, per-bar AnimationController, reacts to isPlaying via didUpdateWidget
- `lib/widgets/shimmer_song_card.dart` — shimmer placeholder matching song_card layout
- Manual AnimationController/TweenAnimationBuilder used throughout — `flutter_animate` NOT added to pubspec (wasn't already there, spec said either was fine)

### ✅ Batch 7 — Widgets (player) (COMPLETE)
- `lib/widgets/mini_player.dart` — StreamBuilder on `audioHandler.mediaItem` + `audioHandler.player.playerStateStream`, black text/icons on kGreen bg, swipe-up (velocity < -200) also opens full player, hides itself when no mediaItem
- `lib/widgets/rotating_vinyl.dart` — 20s loop RotationTransition, stops/resumes on `isPlaying` change via `didUpdateWidget`, kGreen→kBlue radial gradient + glow shadow
- `lib/widgets/progress_slider.dart` — SliderTheme (kGreen), position/total labels, disabled (no crash) when total is zero
- `lib/widgets/animated_play_button.dart` — tap bounce (TweenSequence, elasticOut) + playing pulse (loop 1.0↔1.05), combined scale via `Listenable.merge`
- `lib/widgets/heart_button.dart` — bounce (1.0→1.3→1.0), mediumImpact haptic
- `lib/widgets/cache_indicator.dart` — simple green dot, `SizedBox.shrink()` when not cached (see NOTES.md #6 re: fade-out)
- Note: spec referenced `kGreenBlueGrad` which doesn't exist in `colors.dart` (gradients live under `AppGradients` class) — used inline gradients instead, see NOTES.md #5

### ✅ Batch 8 — Screens onboarding (COMPLETE)
- `lib/screens/splash_screen.dart`
- `lib/screens/onboarding_screen.dart`
- `lib/screens/permission_screen.dart`
- `lib/screens/language_screen.dart`
- `lib/screens/taste_screen.dart`

See NOTES.md #7 — onboarding chain wiring still has a gap (Permission/Taste
unreachable), needs confirming before it's fully end-to-end.

### ✅ Batch 9 — Screens main (COMPLETE)
- `lib/screens/home_screen.dart` — bottom nav (4 tabs via `IndexedStack`), top
  bar + search bar + 12 category chips (`CategoryCard`) + Trending Now list
  (`YoutubeService.search('top hindi songs 2024')`), pull-to-refresh, shimmer
  loading, mini player above bottom nav
- `lib/screens/search_screen.dart` — debounced (500ms) search, recent
  searches + 8 popular chips when empty, `SongCard` results list, empty/
  loading states
- `lib/screens/library_screen.dart` — Liked Songs card (count + play-all),
  Downloads card (count + navigate), Playlists list (`PlaylistDB`) + Create
  placeholder, shimmer loading
- `lib/screens/downloads_screen.dart` — `DownloadDB` list, local playback
  (`audioHandler.playFromFile`), swipe-to-delete + confirm dialog, empty state
- Mini player wired on all 4 screens via `QueueService.currentSong` +
  `LikeService.isLiked` (each screen has its own small private wrapper —
  see NOTES.md #10)
- `HomeScreen` NOT yet wired as the app's `home:` in `main.dart` — that's tied
  to the onboarding flow fix (NOTES.md #7), left untouched this batch

### ✅ Batch 10 — Screens player (COMPLETE)
- `lib/screens/full_player_screen.dart` — vinyl (Hero + rotate), title/artist,
  seek bar, shuffle/prev/play-pause/next/repeat row, 4-chip row (heart/queue/
  timer/lyrics), swipe-down-to-close, sleep timer dialog (15/30/60/90/Off),
  song info via `audioHandler.mediaItem` (same pattern as `MiniPlayer`)
- `lib/screens/queue_screen.dart` — "Now Playing" fixed card + "Up Next"
  `ReorderableListView` (drag handle) + swipe-to-delete, total duration
  header, Clear (confirm dialog), tap-to-jump
- `lib/screens/lyrics_screen.dart` — `SharedPreferences` cache
  (`lyrics_<songId>`) lookup, placeholder text when missing, fullscreen
  toggle
- `lib/screens/equalizer_screen.dart` — 10-band vertical sliders, 12 presets,
  bass boost/3D surround/reverb, Reset, Save Custom → `SharedPreferences`
  (UI + persistence only — see NOTES.md #15 for the DSP limitation)
- `lib/services/queue_service.dart` — extended (not part of the file list,
  but required for the queue screen to compile): added `currentIndex`
  getter + `reorder(oldIndex, newIndex)` method
- All 4 screens' `_MiniPlayerBar` tap placeholders (NOTES.md #12) replaced
  with real `Navigator.push` to `FullPlayerScreen`
- `EqualizerScreen` is built but not yet linked from any nav/settings entry
  point — no screen currently opens it (see NOTES.md #16)

### ✅ Batch 11 — Screens playlist (COMPLETE)
- `lib/screens/create_playlist_screen.dart` — cover picker bottom sheet
  (Emoji/Gradient/Solid tabs), name + description fields, Collaborative +
  Private switches, Save → `PlaylistDB.createPlaylist()`, returns the
  playlist's `id` via `Navigator.pop(context, id)`. Also defines the shared
  `kPlaylistEmojis` / `kPlaylistGradients` / `kPlaylistSolidColors` /
  `coverGradientFor()` constants that `playlist_detail_screen.dart` and
  `add_to_playlist_sheet.dart` both reuse for consistent cover rendering.
- `lib/screens/playlist_detail_screen.dart` — cover + name + song/duration
  count, Play All / Shuffle, `ReorderableListView` (drag handle) + swipe-to-
  remove (`Dismissible`) + long-press remove-confirm, empty state, more_vert
  menu (Rename dialog / Change cover sheet / Share snackbar placeholder /
  Delete confirm). Resolves playlist song ids into full `Song` data by
  merging `LikedDB` + `CacheDB` + `DownloadDB` (see NOTES.md #18).
- `lib/screens/add_to_playlist_sheet.dart` — `showAddToPlaylistSheet(context,
  song)` bottom sheet function, "Create new playlist" tile → pushes
  `CreatePlaylistScreen` and adds the song to the returned id, existing
  playlists list with a checkmark + tap-to-toggle membership, empty state,
  60%-height scrollable sheet.
- `lib/screens/liked_songs_screen.dart` — kRed→kPurple heart cover, Play All
  / Shuffle, `LikedDB` list with swipe-right-to-unlike (`Dismissible`) +
  heart-tap-to-unlike, empty state, `RefreshIndicator`, shimmer loading, a
  `more_vert` "Clear all" action (spec didn't detail this menu's options —
  see NOTES.md #21 heading area for other Batch 11 assumptions).
- `PlaylistDB`'s real API (from Batch 3) differs from what the Batch 11
  prompt assumed (no `updatePlaylist`/`isSongInPlaylist`, `addSongToPlaylist`
  takes a song id not a `Song`, `reorderSongs` takes an ordered id list not
  old/new index, `getPlaylistSongs` returns ids not `Song`s) — all 4 screens
  were written against the actual API. See NOTES.md #17.
- `library_screen.dart` and `search_screen.dart` are **not yet wired** to
  these new screens (out of scope — only 4 files allowed this batch); see
  NOTES.md #21 for what's left to connect.

### ✅ Batch 12 — Artist, Album, Cache Manager, Profile, Stats (COMPLETE)
- `lib/screens/artist_screen.dart` — `SliverAppBar` (expanded 260) collapsing
  header (circle image 140x140, name, "YouTube Artist"), Follow (local UI
  toggle, see NOTES.md #22) + Play All buttons, `YoutubeService.instance
  .search('<naam> songs', max: 20)` results as `SongCard`s, shimmer x5,
  "Kuch nahi mila" empty state, tap → queue + play.
- `lib/screens/album_screen.dart` — same pattern, square cover 180x180
  rounded 16, `SliverAppBar` expanded 280, Play All + Shuffle buttons,
  `YoutubeService.instance.search('<naam> full album')`, shimmer x6.
- `lib/screens/cache_manager_screen.dart` — storage ring chart
  (`CustomPainter`, no package), "X MB / limit" + song count, discrete
  limit slider (500MB/1GB/2GB/5GB/Unlimited → `CacheService.setLimit()`),
  WiFi-only switch (`CacheService.setWifiOnly()`) + Preload-next-song switch
  (local-only, see NOTES.md #23), "Liked songs protected hain" note, Clear
  Cache (full wipe incl. protected) + Clear Unprotected
  (`CacheService.clearAll()`) buttons with confirm dialogs, `CacheDB.getAll()`
  list with swipe-to-delete (blocked if protected) + long-press to
  toggle-protect, `RefreshIndicator`, "Cache khaali hai" empty state.
- `lib/screens/profile_screen.dart` — avatar (initial letter) + name +
  "Haryana", 4-box stats row (Liked/Playlists/Downloads/Hours from
  `LikedDB`/`PlaylistDB`/`DownloadDB` + placeholder `listened_seconds`,
  see NOTES.md #24), section tiles → `LikedSongsScreen`/`LibraryScreen`/
  `DownloadsScreen`/`CacheManagerScreen`/`StatsScreen` (real navigation) +
  Settings/About (Batch 13 placeholders), Logout with confirm dialog
  (UI-only, see NOTES.md #25).
- `lib/screens/stats_screen.dart` — Week/Month/Year/All range chips (demo
  multiplier only, see NOTES.md #24), 2x2 count-up stat grid (Total Played/
  Hours/Top Artist/Streak) reading `played_songs`/`listened_seconds`/
  `streak`/`top_artists` `SharedPreferences` keys, Top Songs + Top Artists
  (real `LikedDB`+`CacheDB` pool, dummy per-song play counts, see
  NOTES.md #24), last-7-days bar chart (`CustomPainter`, reads an extra
  `daily_listened_seconds` key not in the original spec list — defaults to
  zero bars).
- All 5 screens compile standalone; none of them are linked from anywhere
  yet except via `ProfileScreen`'s own tiles (`HomeScreen`/`SearchScreen`
  still don't navigate to `ArtistScreen`/`AlbumScreen` — no artist/album
  tap targets exist in those screens yet, out of scope this batch).

### ✅ Batch 13 — Settings, Background Settings, About, Help + SETUP.md (COMPLETE)
- `lib/screens/settings_screen.dart` — 10 sections (Appearance/Playback/
  Downloads/Cache/Notifications/Privacy/Background/Audio/Advanced/About),
  reusable `_buildSectionHeader`/`_buildSwitchTile`/`_buildNavTile` +
  accent-color row + font-size slider, all backed by `ThemeService`
  (theme mode/accent/font scale/animation speed/dynamic colors) +
  `setting_*`-prefixed `SharedPreferences` keys for everything else
  (see NOTES.md #26 for which toggles are UI-only). Cache Limit tile
  shows live size (`CacheService.currentSize()` + `StorageService
  .formatBytes()`) and pushes `CacheManagerScreen`; Equalizer tile now
  finally links to `EqualizerScreen` (resolves NOTES.md #16); Background
  tile pushes `BackgroundSettingsScreen`; About/Help tiles push
  `AboutScreen`/`HelpScreen`. Clear App Data / Reset App / Delete Account
  all confirm-dialog gated (see NOTES.md #28 for scope assumptions).
  Sleep Timer dialog added here too — independent of Full Player's own
  timer (see NOTES.md #27).
- `lib/screens/background_settings_screen.dart` — Background Play (4
  switches, `bg_`-prefixed keys), Battery Optimization info card + "Open
  Battery Settings" button (manual-instructions SnackBar, no
  platform-intent plugin available), Audio Focus (2 switches), Service
  Status live card (`StreamBuilder` on `audioHandler.mediaItem`).
- `lib/screens/about_screen.dart` — logo/glow header, version, developer
  credit, GitHub link (`url_launcher`), Share App (`share_plus`), Rate
  App placeholder, Open Source Licenses / Privacy Policy / Terms of Use /
  Version History dialogs, Device info tile (`device_info_plus`
  `androidInfo` — see NOTES.md #29 re: Android-only), footer copyright.
- `lib/screens/help_screen.dart` — search bar filtering a 10-question
  Hinglish FAQ (`ExpansionTile` list), empty-search state, "Report Bug"
  button (`url_launcher` → GitHub issues, SnackBar fallback).
- `SETUP.md` — full setup guide (requirements, file tree, zip-upload +
  GitHub Actions APK-build workflow, troubleshooting, features list,
  credits, license).
- `profile_screen.dart`'s Settings icon is **not yet wired** to the new
  `SettingsScreen` (out of scope this batch — see NOTES.md #31).

### ⬜ Remaining batches (order)
- ✅ Batch 14A (FIX Part 1) — DONE (see below).
- ✅ Batch 14B (FIX Part 2, final) — DONE (see below).
- ✅ Batch 15 (Final Fix, post-audit) — DONE (see below).
- Batch 16+ (if user continues): go through remaining `NOTES.md` items
  that are still open (not marked RESOLVED) and close as many as make
  sense — e.g. shared `SleepTimerService` (#27), UI-only settings toggles
  (#26), real tracking engines for Stats (#24) / Follow (#22) / Preload
  (#23) if wanted.

### ✅ Batch 14A — FIX Part 1 (COMPLETE)
9 files updated (+1 supporting file touched, flagged below):
- `lib/screens/splash_screen.dart` — checks `onboarding_done` after the 2s
  animation, goes to `HomeScreen` (already onboarded) or `OnboardingScreen`
  (first time)
- `lib/screens/onboarding_screen.dart` — no change needed, already targeted
  `LanguageScreen` correctly
- `lib/screens/language_screen.dart` — Continue target changed
  `OnboardingScreen` → `PermissionScreen` (this was the actual source of the
  old Language↔Onboarding loop)
- `lib/screens/permission_screen.dart` — no change needed, already targeted
  `TasteScreen` on both Next/Skip
- `lib/screens/taste_screen.dart` — now sets `onboarding_done=true` and
  navigates to the real `HomeScreen`; removed the old placeholder Home widget
- `lib/main.dart` — added a `_Boot` StatefulWidget as the app's `home:`,
  checks `onboarding_done` at startup to show `HomeScreen` directly
  (skipping the splash animation for returning users) or `SplashScreen`
  (first launch); all existing audio/provider init logic untouched
- `lib/screens/profile_screen.dart` — Settings icon + Settings/About tiles
  now push `SettingsScreen`/`AboutScreen`; removed the unused placeholder
  snackbar helper
- `lib/screens/library_screen.dart` — Liked Songs card → `LikedSongsScreen`,
  playlist tap → `PlaylistDetailScreen(playlistId: p.id)`, Create →
  `CreatePlaylistScreen`, all three refresh the list on return
- `lib/screens/search_screen.dart` — `SongCard`'s download icon replaced
  with a `playlist_add` icon wired to `showAddToPlaylistSheet` (removed the
  now-unused `_download()` helper)
- `lib/widgets/song_card.dart` (supporting change, not in the original
  9-file list) — added an optional `onAddToPlaylist` param and made
  `onDownload` optional too; when `onAddToPlaylist` is null (all 6 other
  screens using `SongCard`) it renders exactly as before

Onboarding chain is now fully wired end-to-end:
`Splash → Onboarding → Language → Permission → Taste → Home`.
See `NOTES.md` #7, #13, #21, #31, #32 for details on what changed.

### ✅ Batch 14B — FIX Part 2, final (COMPLETE)
4 files updated (+1 supporting file touched, flagged below):
- `lib/db/playlist_db.dart` — DB version 1 → 2 (`onUpgrade` with
  per-statement try-catch `ALTER TABLE`); `playlists` table gained
  `description TEXT` + `is_private INTEGER DEFAULT 0`; `playlist_songs`
  table gained `title`/`artist`/`thumb`/`duration`; new methods
  `updatePlaylist()`, `isSongInPlaylist()`, `setPrivate()`;
  `addSongToPlaylist()` now takes a full `Song` (was `String songId`);
  `getPlaylistSongs()` now returns `List<Song>` (was `List<String>`)
  with automatic fallback to Liked/Cache/Download DB for old rows that
  have no stored title
- `lib/models/playlist.dart` — added `description` (String?) and
  `isPrivate` (bool, default false), wired into `fromMap`/`toMap`/`copyWith`
- `lib/screens/create_playlist_screen.dart` — description + private switch
  now load in edit mode and persist on save (`updatePlaylist()` when
  editing, `createPlaylist()` when creating new)
- `lib/screens/playlist_detail_screen.dart` — removed the old
  `_resolveSongs()` helper; now calls `PlaylistDB.instance.getPlaylistSongs()`
  directly since it returns `List<Song>` already (fallback logic moved
  into `PlaylistDB` itself)
- `lib/screens/add_to_playlist_sheet.dart` (supporting change, not in the
  original 4-file list) — 2 lines changed (`widget.song.id` →
  `widget.song`) at its two `addSongToPlaylist()` call sites, required by
  the signature change above to keep the build compiling

See `NOTES.md` #18, #19, #33 for details on what changed.

### ✅ Batch 15 — Final Fix (COMPLETE)
Post-audit fix — 2 code files + 2 markdown files updated:
- `pubspec.yaml`: assets section comment kiya (folder exist nahi karta —
  ye pehle `flutter build apk` fail karwa sakta tha), `flutter_launcher_icons`
  config bhi comment kiya (`app_icon.png`/`app_icon_fg.png` files exist nahi
  karti)
- `.github/workflows/build.yml`: naya "Create Android scaffold" step add
  kiya (`flutter create . --platforms=android --org com.sursathi
  --project-name sursathi --no-overwrite`), `Pub get` step se pehle —
  Android scaffold (build.gradle, MainActivity, res/mipmap icons, gradle
  wrapper) ab auto-generate hota hai, `--no-overwrite` custom
  `AndroidManifest.xml` ko safe rakhta hai

See `NOTES.md` "RESOLVED IN BATCH 15" for details.

### ✅ Post-Batch-15 Fix — YouTube Search/Stream Failure (COMPLETE)
5 files updated (2 code files changed logic, 1 new file, 1 UI hook, 1
manifest comment-only):
- `pubspec.yaml` — `youtube_explode_dart: ^2.0.2` → `^3.1.0` (root cause:
  2.0.2 YouTube ne block kar diya tha), `path: ^1.8.3` → `^1.9.1`
  (transitive requirement), `audio_service` patch-bump `^0.18.18`
- `lib/services/youtube_service.dart` — client list ab
  `androidSdkless → androidVr → ios → android → mweb` (pehle sirf
  `androidVr, android, mweb` the, aur `androidSdkless` exist hi nahi karta
  tha 2.0.2 me) + `search()`/`getAudioUrl()`/`download()` teeno me error
  logging
- `lib/screens/debug_screen.dart` (naya) — Test Search / Test Audio URL /
  Test Direct Video buttons, dark theme
- `lib/screens/home_screen.dart` — AppBar me `bug_report` icon add kiya,
  settings icon ke paas, `DebugScreen` pe navigate karta hai
- `android/app/src/main/AndroidManifest.xml` — verification comment add
  kiya (INTERNET permission already tha, cleartext jaanbujhke false rakha)

**Root cause:** purana package version (Aug 2023) YouTube ke current API
ke saath kaam nahi kar raha tha, aur jo `android` client use ho raha tha
wo audio-only streams pe YouTube ka PO-Token check trigger karta tha.

**Recommendation agar YouTube phir se block kar de (Task 6, apply nahi
kiya gaya — sirf reference ke liye):**
- Sabse pehle `youtube_explode_dart` ko phir se latest version pe check
  karna (`pub.dev/packages/youtube_explode_dart`) — active maintained
  library hai, aksar 1-2 hafte me fix aa jaata hai.
- Agar poori library hi block ho jaye: **Piped API** (piped.video ke
  public/self-hosted instances) ek REST API deta hai jo YouTube search +
  stream URLs deta hai bina YouTube ka client-side logic replicate kiye —
  sabse kam maintenance wala fallback. **Invidious** bhi similar hai lekin
  instances kam reliable hain aajkal.
- **yt-dlp server-based approach** (khud ka small backend jo yt-dlp
  chalaye aur app usse REST call kare) sabse robust hai kyunki yt-dlp ki
  community youtube_explode_dart se bhi zyada active hai, lekin isme ek
  alag server (VPS/Cloud Run) maintain karna padega — phone-only workflow
  ke liye ye extra complexity hai.
- Filhaal koi bhi in teeno me se apply nahi kiya gaya hai — sirf recommendation.

See `NOTES.md` #34 for full details.

### Batch 21 — NewPipeExtractor added as primary (crash/stale-search fixes)
`newpipeextractor_dart` (WebView-based Flutter wrapper) add kiya gaya tha
audio-fetch ke liye + kai crash/pagination bugs fix hue (`_searchSeq`
guard, `_newPipeLock` mutex, `skipToNext()` replay-loop bug). Poori
details `NOTES.md` me Batch 21 heading ke neeche hain.

### Batch 22 — Option C: native NewPipeExtractor plugin (no more WebView)
User ne 3 options me se **Option C** choose kiya: `newpipeextractor_dart`
+ `flutter_inappwebview` (WebView) poori tarah hata di gayi, unki jagah
apna native Kotlin plugin (`android/app/.../newpipe/NewPipeDownloader.kt`
+ `NewPipeAudioChannel.kt`, MethodChannel se wired) jo asli NewPipeExtractor
Java library ko seedha call karta hai — bilkul OuterTune/OpenTune jaisa,
koi WebView nahi. **NOT YET COMPILE-TESTED** (is session me Android SDK
available nahi tha) — pehla CI build compile-errors de sakta hai, standard
batch-by-batch flow se fix karna. Poori details `NOTES.md` Batch 22 me.

## Features (poore app ka scope, reference ke liye)
YouTube search + stream + download; Home categories (Bollywood, Punjabi,
Haryanvi, Lo-Fi, Party, Romantic, Workout, Old Hits, Arijit, Chill,
Devotional, Hip-Hop); live debounce search; Liked Songs (heart + pulse
animation); auto-cache 2GB LRU (liked songs protected); permanent Downloads
(Music/SurSathi/); mini player + full player (rotating vinyl, equalizer
bars); background play + notification + lock screen controls; queue,
shuffle, repeat, sleep timer; Settings (theme, cache limit, notifications);
heavy animations (stagger, slide, fade, scale, shimmer); splash screen glow
pulse; onboarding screens.

## Agle instance ke liye instruction
Repo me is zip ke andar ki files ko exact isi path structure me copy kar do
(`lib/...`, `android/...`). Batch 1-15 dobara mat banana — sab complete
hai. Agla kaam agar user "next" bole to: `NOTES.md` me jo items abhi bhi
open hain (RESOLVED wale chhodo) unko ek-ek karke fix karna.

Har batch complete hone ke baad ye README dobara update karna hai (status
section) aur poori project ka fresh zip re-generate karke dena hai — ye
user ki standing instruction hai, har batch pe repeat karna. Koi bhi gap/
assumption/limitation aaye to `NOTES.md` me alag se add karna (README me
nahi) — ye bhi user ki standing instruction hai.
