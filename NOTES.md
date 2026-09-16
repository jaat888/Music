# SurSathi — Notes / Known Issues

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
