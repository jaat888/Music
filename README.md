# SurSathi — Flutter Music App — Progress Notes

> ⚠️ **PEHLE YE PADHO (naya Claude instance bhi, koi bhi kaam shuru karne se
> pehle):**
> 1. **Streaming/resolve wale code mein chhed mat karo** — `youtube_service.dart`,
>    `innertube_client.dart`, aur `background_service.dart` ke play/resolve/CDN-header
>    wale hisse bahut fragile hain aur bahut round-trip le chuke hain. Sirf tabhi
>    haath lagao jab user khud isi cheez ka koi specific bug bataye — "cleanup"
>    ya "refactor" ke naam pe kabhi mat chhedo.
> 2. **Notification icon crash baar-baar recur ho chuka hai**
>    (`Invalid notification (no valid small icon)`, channel `com.sursathi.audio`).
>    Fix in teen jagah hai — inhe kabhi delete/revert/"simplify" mat karo:
>    - `background_service.dart` → `androidNotificationIcon: 'drawable/ic_notification'`
>    - `android/app/src/main/res/drawable/ic_notification.xml` (custom icon)
>    - `android/app/src/main/res/raw/keep.xml` (`tools:keep`) + `build.gradle`
>      me `minifyEnabled false, shrinkResources false` — resource shrinker se
>      is drawable ko protect karta hai.
>    Details: `NOTES.md` me top pe aur usi neeche.

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

### Batch 95 — Extra curated-playlist sources: JioSaavn + iTunes (2026-09-19)
Home screen pe pehle se maujood live YT Music feed (`getHomeFeed()` —
Categories, "Dancing on your own", "India's biggest hits" jaisi sections)
ke SAATH, do naye playlist sources jode:
- **JioSaavn** (`jiosaavn_service.dart`) — koi login/API-key nahi, JioSaavn
  ka apna undocumented endpoint (jo saari open-source JioSaavn wrapper
  libraries use karti hain). App ki existing categories (Bollywood,
  Punjabi, Haryanvi, ...) reuse karke unki editorial/curated playlists
  dhoondta hai — "India ki Playlists" section, Home screen pe.
- **iTunes/Apple Music** (`itunes_charts_service.dart`) — Apple ka free,
  keyless, public "Marketing Tools" chart feed (`rss.marketingtools.apple.com`)
  — India ka "Most Played" Top-50 chart, ek card ki tarah ("iTunes — India
  Top Songs").

Dono sources se sirf **title + artist metadata** aata hai — audio hamesha
YouTube se hi resolve hota hai (naya `curated_playlist_screen.dart`,
`import_playlist_screen.dart` ke Spotify-import-branch jaisa hi pattern:
ek-ek track YouTube pe search karke best-match video se play hota hai).
Dono naye sources `home_screen.dart` ke asli YT-feed load se **independent**
hain (alag `try/catch`, alag loading-flag) — koi bhi ek down/slow/shape-
change ho to baaki sab (asli YT feed included) normally kaam karte rahenge.
Pull-to-refresh (`_refreshAll()`) teeno source refresh karta hai.

**STATUS — is dev-environment mein compile-test NAHI ho paaya** (yahan
Flutter/Dart toolchain nahi hai). JioSaavn ka endpoint reverse-engineered/
undocumented hai — agar JioSaavn apna response-shape badal de, poori
defensive parsing (`jiosaavn_service.dart`) ke through wo section bas
khaali reh jaayega (crash nahi), lekin real device pe ek baar confirm
zaroor karna ki "India ki Playlists" section mein data aa raha hai.
iTunes ka feed Apple ka official/stable format hai, kam risk hai.

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

### 🆕 2026-09-17 — PoToken (BotGuard) real fix (UNTESTED, dekho NOTES.md)
Naya `lib/services/potoken_service.dart` + `main.dart` me hidden WebView
host + `webview_flutter` dependency — stream-drop (CDN 403/terminate) ka
asli fix. Fail-soft hai. Poora detail + testing checklist NOTES.md me.

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

### Radio Mode — Phase 3

The standalone `radio_engine.dart` layer now handles Radio Mode candidate
pooling and weighted selection. It enforces the existing non-repeat history,
balances selected languages, keeps an approximate hits/latest mix, applies
mood scores, and can build a short look-ahead buffer. Playback/stream resolve
continues through the existing pipeline.

## Radio Mode — Part 5
Part 5 adds the reel-style Radio Player after language selection. It supports play/pause, one-step previous, favorite, swipe-to-skip, automatic next-track handling, and a small candidate look-ahead buffer. Candidate selection continues to use the Part 3 Radio engine and recent-history rules. Playback itself continues through the existing audio handler.

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

### Radio Mode — Part 8
Radio Player now attempts to load cached/timed lyrics and displays a compact synced subtitle strip when LRC timing is available. Missing/failed lyrics are silently ignored so playback continues normally.

### Radio Mode — Part 9

The Home top bar now exposes a clean, accessible Radio Mode entry icon that opens the existing language-selection flow directly. This is a UI entry-point change only; the protected playback/resolve pipeline remains untouched.

## Radio Mode — Part 10

Documentation/status phase completed. Radio Mode Phases 1–9 are now recorded here and in `NOTES.md` / `FEATURE_ROADMAP.md`. Part 10 makes no runtime or protected-pipeline changes.

## Radio Mode — Parts 11–12
- Part 11 finalized Radio tuning defaults: 90-day history window, session-only mood state, one-step Previous, and centralized skip/decay constants.
- Part 12 hardened Radio Player transitions against rapid double swipe/auto-next/Previous races.
- Existing protected playback/resolve/CDN/background pipeline remains untouched.

## Radio — Post Part 3–12 Bug-Fix Audit (2026-09-17)

- Fixed Radio completion ownership: while `RadioPlayerScreen` is active, the global `AudioHandler` completion listener no longer advances the normal `QueueService`; Radio owns its own auto-next transition.
- Fixed Radio transition subscription lifecycle: the Radio completion listener is cancelled on screen dispose.
- Fixed mood-decay accounting: skip penalties are now stored separately from the base mood score, so even escalated penalties recover exponentially instead of permanently lowering the base score.
- Fixed multi-language eligibility: fresh/fallback selection is evaluated per language, so an exhausted language cannot disappear merely because another selected language still has fresh candidates.
- Improved hits/latest candidate sampling by shuffling within each bucket before applying the approximate 60/40 target.
- Fixed stale cache metadata: when a CacheDB row points to a missing audio file, the stale row is removed during local-cache lookup.
- Existing 15-song recent cache and favorite-protected cache behavior remains intact.
- Protected resolve/CDN pipeline remains unchanged apart from the additive Radio completion-ownership hook.


## V107 — 2026-09-19 — Deep bug-fix pass by ChatGPT (OpenAI)

V106 ke Radio signal + shuffle work ke baad ek second deep source audit kiya gaya. User-requested V107 pass me 17 concrete race/state bugs patch kiye gaye.

### Kya fix hua, aur V106 me kyu hua

1. **Native source-prepare race:** `Future.timeout()` underlying just_audio prepare ko cancel nahi karta tha. V107 active prepare ko track karke replacement se pehle stop/unwind + generation guard karta hai.
2. **Stop ke baad stale recovery:** stop explicit user intent tha, lekin old source operation zinda reh sakta tha. V107 stop source/play generations invalidate karta hai aur active prepare abort karta hai.
3. **Silent mid-play stall:** buffering-state-only watchdog silent READY freeze miss kar sakta tha. V107 position-progress watchdog use karta hai.
4. **Radio stale completion:** shared player ka delayed `completed` event current Radio candidate par false auto-next kar sakta tha. V107 completion ko confirmed-start + near-end checks se gate karta hai.
5. **Radio candidate fetch race:** async old search direct shared `_candidates` mutate karta tha. V107 local staging + session/fetch generations use karta hai.
6. **Recovery Future collision:** recovery lock sirf song ID tha. V107 candidate generation ko identity me include karta hai.
7. **Previous fallback gap:** Previous ek hi old candidate try karta tha. V107 bounded fallback loop use karta hai.
8. **Queue radio refill race:** old supplier Future active queue me late results append kar sakta tha. V107 generation/supplier checks + ID dedupe lagata hai.
9. **Search pagination singleton:** ek query ki continuation doosri query se clobber ho sakti thi. V107 per-query state map use karta hai.
10. **Radio continuation singleton:** multiple radio seeds continuation overwrite kar sakte the. V107 per-seed state map use karta hai.
11. **Audio focus not initialized:** service file thi, startup wiring missing thi. V107 phone interruption/duck/headphone callbacks configure karta hai.
12. **Favorite score drift:** repeated like/unlike boost ko one-way add karta tha. V107 counted reversible boost use karta hai.
13. **Stale artwork/metadata prefetch:** old Radio candidate ka slow preload continue hota tha. V107 generation cancellation checks add karta hai.
14. **Progress raw playing:** button effective signal use karta tha, progress raw `player.playing`. V107 same effective signal wire karta hai.
15. **NewPipe unbounded workers:** `newCachedThreadPool()` resolver bursts me unlimited workers bana sakta tha. V107 fixed 2-worker executor use karta hai.
16. **Load More page-1 duplication:** continuation fail hone par generic search page-1 ko load-more maana ja sakta tha. V107 compatible InnerTube continuation ke bina relevance Load More stop karta hai.
17. **Theme Navigation reset:** keyed `MaterialApp` theme switch par Navigator recreate karta tha. V107 key remove karta hai, navigation preserve hoti hai.

### Validation

Flutter/Dart SDK is environment me available nahi tha, isliye `flutter analyze`, `flutter test`, APK build aur real-device tests run nahi hue. V107 is source-level/diff-validated patch hai; final device test abhi required hai.

### Version

`1.0.0+554`

Detailed root-cause/change notes: `V107_CHATGPT_BUGFIX.md` and `NOTES.md`.


## V108 — 2026-09-19 — Radio candidate generation + preload hardening

V107 ke baad Radio ke “next song kabhi generate nahi hota / preload miss hota hai” flow ko dobara trace karke hardening ki gayi. Ye pass specifically candidate exhaustion, warm-URL preload reliability aur stale preload work ko target karta hai.

### Kya badla

1. **Radio candidate pool top-up:** initial 2 searches ke baad agar pool chhota ho, real InnerTube continuation pages se extra candidates fetch kiye jaate hain; same first page ko sirf duplicate merge ke liye use kiya jaata hai.
2. **Look-ahead refill self-heal:** 10-song upcoming window fill na ho to candidate pool refresh karke dobara selection hoti hai, isliye long sessions me initial finite batch par session dead nahi hota.
3. **Radio URL warm window 1 → 3:** next 3 songs ke stream URLs warm kiye jaate hain; actual full-track downloads nahi kiye jaate.
4. **Warm URL queue:** duplicate requests ko dedupe kiya gaya; stale queued jobs ko new Radio window ke bahar prune kiya jaata hai.
5. **Warm URL retry:** har preload resolve ko max 2 attempts milte hain; failures ab silently swallow nahi hote, logs me reason/attempt dikhta hai.
6. **Warm URL TTL:** URL cache 5 minutes se purana ho to fresh resolve kiya jaata hai, taaki stale signed media URL ko permanent valid na maana jaaye.
7. **Serial extraction retained deliberately:** prefetch ek hi serialized worker se hota hai, taaki YouTube extraction/request burst na bane; foreground playback ko unlimited background resolver fan-out se compete nahi karna padta.
8. **Prefetch is URL warm-up, not guaranteed player buffer:** current architecture shared AudioPlayer ko background me next URL ke liye `setUrl()` nahi karta, kyunki aisa karna current playback source replace kar dega. Isliye V108 “URL prefetch” guarantee karta hai, full decoded audio-buffer guarantee nahi.

### Root cause note

Radio me 3 alag stages hain: candidate generation → URL warm-up → actual player buffering. In teenon ko pehle ek hi “preload” naam se treat kiya ja raha tha. V108 in stages ko explicitly separate karta hai aur first two stages ko more resilient banata hai.

### Validation

Flutter/Dart SDK is environment me available nahi tha, isliye `flutter analyze`, `flutter test`, APK build aur real-device test run nahi hue. Static source/diff validation ki gayi.

### Version

`1.0.0+554` → `1.0.0+555`


## v109 Radio learning update

On 2026-09-19, ChatGPT added a functional adaptive Radio feedback loop. v108 mostly ranked by mood, likes, search rank and existing history. The missing signals were explicit completion ratio, replay count, skip timing and short-term artist fatigue. Those gaps could make a 5-second skip and a near-complete listen look too similar at ranking time, and could allow one artist to appear too frequently. v109 stores `listenSeconds`, `completionRatio`, and `replayCount`, learns from exact skip timing, preserves old v108 history defaults, penalizes recently repeated artists, and applies diversity while building the next-song window. This is an original SurSathi implementation inspired by public descriptions of behaviour-based recommendation, not a reproduction of Resso's private algorithm.


### V110 preload consistency patch
The Radio player no longer has two competing preload callers with different look-ahead sizes. The old `_playCandidate()` `take(2)` prefetch path was removed; `_fillUpcoming()` now owns the look-ahead and the existing 3-song Radio warm-up path. This corrects the V108/V109 implementation/documentation mismatch.

## V111 — Radio learning correctness fix

- Radio short-term artist fatigue now uses persisted 45-minute `recentArtistCounts()` plus the immediate in-memory session tail.
- Skipped-song timing is no longer counted twice through generic tag/artist affinity and dedicated skip-timing affinity.
- Added regression tests for both behaviours.

Version: `1.0.0+561`


## V114 — Radio freshness / strict language / duration

See `V114_RADIO_90DAY_2YEAR_LANGUAGE_DURATION_FIX.md` for the Radio policy change.

## V113 — Deep playback race hardening

See `V113_DEEP_PLAYBACK_RACE_FIX.md` and the top section of `NOTES.md` for the exact bugs fixed, root causes, and validation limits.


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


--- V116 ---
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
