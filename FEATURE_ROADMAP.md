# SurSathi — Feature Roadmap (Baad me karna, abhi ka build fix ho jaye pehle)

Ye file un features ki list hai jo discuss hui (OpenTune/InnerTune jaisi
app dekh ke) aur SurSathi me add karni hain. Pehle current CI build
(gradle/proguard/jitpack) stable karo, phir yaha se ek-ek karke pick karo.

Status legend: `[ ]` not started · `[~]` partially possible with existing
deps · `[!]` needs new dependency or native code

---

## 1. Live/updated playlist aur search (YouTube Music "innertube" style)

**Abhi:** `youtube_service.dart` sirf `newpipeextractor_dart` (+ backup
`youtube_explode_dart`/Piped) pe depend karta hai — search aur playlist
dono isi se aa rahe hain.

**Kya alag hoga:** OpenTune/InnerTune YouTube Music ke internal/private
"innertube" protocol (wahi jo asli YT Music app/web use karta hai) seedha
call karte hain search/home-feed/playlist/browse ke liye — isliye unka
data zyada "live" (real-time, YT Music ke actual backend se) lagta hai.
NewPipeExtractor sirf **stream URL resolve karne** ke liye use hota hai,
poori catalog ke liye nahi.

**Karna kya hoga:**
- [ ] Ek Dart innertube-style client dhoondo/banao (ya `youtube_explode_dart`
      ka relevant hissa use karo) jo search/playlist/browse YT Music ke
      internal endpoints se kare
- [ ] `youtube_service.dart` me search/playlist fetching is naye client pe
      shift karo; `newpipeextractor_dart` sirf stream-URL-resolve ke liye
      rakho
- [ ] Fallback chain document karo: innertube client fail → youtube_explode_dart
      → Piped (jaisa abhi hai)

**Priority:** Medium-high — isse search/playlist quality directly improve
hogi.

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
