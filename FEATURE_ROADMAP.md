# SurSathi — Feature Roadmap (Baad me karna, abhi ka build fix ho jaye pehle)

Ye file un features ki list hai jo discuss hui (OpenTune/InnerTune jaisi
app dekh ke) aur SurSathi me add karni hain. Pehle current CI build
(gradle/proguard/jitpack) stable karo, phir yaha se ek-ek karke pick karo.

Status legend: `[ ]` not started · `[~]` partially possible with existing
deps · `[!]` needs new dependency or native code

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
