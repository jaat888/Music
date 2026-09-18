# Part 8 — Radio Mode (Mood-Based Continuous Player)

**Status:** Part 1-5 implementation in progress/completed. Phases 1-4 and 5 have been implemented in the current project ZIP. Remaining phases continue below.

**Protected pipeline rule follow hogi:** Radio Mode `youtube_service.dart`, `innertube_client.dart`, aur `background_service.dart` ke protected methods (`_resolveAndPlay`, `playSong`, `_playSong`, `playWithRetry`, `_handleStreamDrop`, `_retryAfterStreamDrop`, CDN-header code) ko touch nahi karega. Radio Mode ek naya layer hoga jo in existing functions ko **normal tareeke se call** karega (jaise app ke baaki screens karte hain), bas queue/selection logic naya hoga.

---

## 1. Feature Summary

Ek naya "Radio Mode" — jaise ek radio station chalu ho jaye aur bina rukhe gaane bajte rahein, user ke current mood ke hisaab se. Koi manual playlist banane ki zarurat nahi.

Key cheezein:
- User 1 ya usse zyada **language(s)** chunta hai (min 1, max = jitni bhi available hain)
- Gaane **type/mood** ke basis pe chunte hain, artist ke basis pe nahi
- **Skip = us mood/type ka gana thodi der ke liye kam** aayega (permanent block nahi — mood wapas aa sakta hai)
- **4-6 mahine tak koi gana repeat nahi** hoga
- Minimal reel-jaisi UI: play/pause, previous, favorite, swipe se skip
- ☰ menu se reset + language change (confirm warning ke saath)
- Neeche auto-sync (best-effort) subtitles/lyrics — na mile to silently normal gana chalega

---

## 2. Caching — NAHI CHAHIYE (confirmed)

User ne clarify kiya: **repeat nahi hoga, isliye pre-caching/downloading ki zarurat nahi.**

- Radio Mode ke gaane **sirf stream** honge (existing streaming pipeline se, jaisa normal play hota hai), disk pe auto-cache/pre-download nahi karenge
- Existing app ka **manual download feature** (jo already hai — download button se explicitly save karna) alag hai aur unaffected rahega — user chahe to radio mein bhi manually download tap kar sakta hai
- `_autoCacheInBackground()` / `_prefetchNext()` jaisi cheezein Radio Mode ke liye **trigger nahi** hongi — sirf normal per-song resolve+stream hoga jab wo gana baje
- Isse do fayde: (a) protected pipeline ke paas se guzarne wala extra code kam hota hai, (b) disk space waste nahi hota kyunki wapas sunne ka chance hi nahi (4-6 mahine tak)

---

## 3. Data Layer (naya, local-only — koi backend/server nahi)

Sab kuch **SharedPreferences + local storage** (existing app ke pattern jaisa hi — jaise stats/equalizer settings persist hote hain).

### 3.1 `radio_history` (list, purge after 4-6 months)
Har entry:
```
{
  songId: string,
  title: string,
  tags: [string],        // e.g. ["romantic", "slow"]
  language: string,
  playedAt: timestamp,
  wasSkipped: bool,
  skipPositionSec: int?  // kitni der sun ke skip kiya
}
```
- Purge logic: app start pe (ya periodically) 4-6 mahine se purane entries auto-delete
- Ye list hi non-repeat rule enforce karegi

### 3.2 `radio_mood_scores` (in-memory + session-level, optional light persistence)
Har `tag` ka ek running score:
```
{ tag: "romantic", score: 72, lastSkippedAt: timestamp }
```
- Session-level by default (app/radio dobara khole to fresh) — kyunki mood daily/hourly change hota hai
- Persistence optional future enhancement nahi hai abhi ke scope mein

### 3.3 `radio_session` (temporary, in-memory)
- Selected languages
- Current queue-ahead buffer (agle 3-5 gaane pre-selected, taaki lag na ho)
- Consecutive-skip counter (per tag)

### 3.4 Gaane ka "type/tag" kaise milega
- Existing YouTube search/category metadata se (jaisa app already "Bollywood Fire", "90s Bollywood Dance" categories dikhata hai)
- Title mein keyword matching (Hindi/English dono): `sad`, `dard`, `judai`, `romantic`, `pyaar`, `party`, `dance`, `slow`, `energetic`, `devotional`, `bhakti`, `wedding`, `shaadi`, `breakup` etc. — ek predefined keyword→tag mapping dictionary
- Ek gaane ko **multiple tags** mil sakte hain (jaise "romantic" + "slow")
- Match na mile to fallback tag: `"mixed"`
- Ye best-effort hai, 100% accurate nahi hoga — documented limitation

---

## 4. Skip = Temporary Mood Decay (core algorithm, detail mein)

### 4.1 Jab user skip kare:
1. Us gaane ke saare tags ka score turant girta hai:
   ```
   new_score = current_score - SKIP_PENALTY   // e.g. SKIP_PENALTY = 15
   ```
2. `lastSkippedAt` timestamp update hota hai us tag ke liye

### 4.2 Decay (recovery) over time
Jab bhi agla gana select karna ho, pehle current effective score nikalte hain:
```
elapsed = now - lastSkippedAt
recovered = SKIP_PENALTY * (1 - e^(-elapsed / DECAY_CONSTANT))
effective_score = base_score - SKIP_PENALTY + recovered
```
- `DECAY_CONSTANT` ≈ 25-30 minutes — matlab ~25-30 min mein penalty ka ~63% wapas recover, ~1.5-2 ghante mein ~95%+ recover (near-normal)
- Simplified alternative (agar exponential decay implement karna heavy lage): step-based recovery — har 15 min mein penalty ka 25% wapas add ho, 4 steps (1 ghanta) mein full recover

### 4.3 Consecutive-skip escalation
- Agar same tag ke 2-3 gaane lagatar skip ho → us tag pe extra penalty (jaise double) aur/ya lamba decay time — system "samajhta" hai abhi mood bilkul nahi hai
- Counter reset ho jata hai jaise hi us tag ka gana **poora sun liya ya skip nahi kiya**

### 4.4 Selection mein use
Agla gana choose karte waqt, candidate pool ke har gaane ko final score milta hai:
```
pick_score = popularity_weight 
           + recency_weight 
           + avg(effective_tag_scores for this song's tags)
           + random_jitter (small, for natural variety)
```
- Jis tag ka effective score sabse kam hai, uske gaane **kam chance** se pick honge (block nahi, bas weight kam)
- Weighted random selection top-N candidates mein se (sirf highest-score wala hamesha nahi — taaki predictable/robotic na lage)

---

## 5. Non-Repeat Rule (4-6 months)

- Candidate pool banate waqt, `radio_history` mein maujood `songId` (jo abhi purge nahi hue, matlab last 4-6 mahine ke andar bajaye gaye) **exclude** kiye jayenge
- Agar selected language(s) ka pool bahut chhota nikle aur "naye gaane khatam" jaisi situation aaye:
  - Graceful fallback: sabse purane history wale gaane (jo 4+ mahine se sune hi nahi) wapas eligible ho jayenge
  - User ko kabhi "no songs found" jaisa dead-end na aaye

---

## 6. Language Selection (multi-select, confirmed)

- **Min: 1**, **Max: no cap** (jitni bhi categories/languages app mein available hain — Haryanvi, Punjabi, Bollywood, aur future mein add hone waali bhi)
- UI: chip/checkbox multi-select style, "Start Radio" button tabhi enable jab ≥1 selected ho
- Reset/☰ → language screen pe wapas aaye to **pehle se selected languages pre-ticked** dikhein (edit karna easy, dobara sab se select na karna pade)

### Multi-language pool mixing
- 2+ languages selected ho to pool sabka combined banega
- Roughly **equal-weight distribution**: 2 languages → ~50/50, 3 → ~33/33/33 (approx, exact nahi, taaki koi language dab na jaye)
- Baaki sab (mood decay, non-repeat, hits/latest split) is combined pool pe hi apply hota hai

---

## 7. "All-Rounder Mix" — Hits vs Latest (per language)

Har language ke pool ko do buckets mein dekha jata hai:
- **Hits/evergreen bucket** — popular/frequently-suggested gaane
- **Latest bucket** — recent upload/release

Default ratio: **~60% hits + ~40% latest** (tunable constant, easy to adjust later)

Final candidate scoring (recap, poora formula):
```
pick_score = base_popularity_weight 
           + recency_weight 
           + mood_effective_score(tags)
           - (already_in_recent_history ? -infinity : 0)   // hard exclude
           + small_random_jitter
```

---

## 8. UI / Screens Flow

### 8.1 Entry point
- Top bar mein naya icon (currently empty space, jahan screenshot mein circle kiya tha) → Radio Mode khulta hai

### 8.2 Language Select Screen
- Multi-select chips: Haryanvi / Punjabi / Bollywood / etc.
- "Start Radio" button (disabled jab tak ≥1 select na ho)

### 8.3 Radio Player Screen (reel-style, minimal)
- **Sirf ye controls:** Play/Pause, Previous (last gana), Favorite/Like, swipe-based skip/next
- **Hata denge:** shuffle, repeat, queue list, playlist add — in sab icons pe user ne cross laga ke dikhaya tha
- Swipe gesture (Instagram Reels jaisa) → agla gana (skip trigger karega mood-decay logic)
- Neeche: auto lyrics/subtitle strip — best-effort sync (section 9 dekhein)

### 8.4 ☰ Menu (top-right, 3-line icon)
- Sirf ek option: **"Reset & Change Language"**
- Tap karne pe **confirm warning dialog** ("Radio reset ho jayega, session ka mood data clear ho jayega — continue?")
- Confirm karne pe → Language Select Screen pe wapas (pehle se selected pre-ticked)

---

## 9. Lyrics / Subtitle Auto-Sync (best-effort)

- Agar existing lyrics source **timed data (LRC-jaisa, timestamp ke saath)** deta hai → line-by-line sync dikhayenge, gaane ke progress ke saath
- Agar sirf **plain text lyrics** milte hain (bina timestamp) → sync possible nahi, is case mein subtitle strip **simply nahi dikhayenge** (ya static full-lyrics button de denge, sync wala nahi)
- **Fail-soft hamesha:** lyrics na mile, load fail ho, ya timing na mile — gaana **normal chalta rahega**, koi bhi error user ko block nahi karega
- *(Implementation se pehle check karna hoga: current lyrics source timed data deta hai ya nahi — isi se pata chalega sync possible hai ya sirf static lyrics)*

---

## 10. Favorite / Like Behavior (radio screen se)

- Radio player screen ka heart/favorite button tap karne pe:
  - Gana existing **"Liked Songs"** list mein save hoga (jaisa app mein already hota hai)
  - Us gaane ke tags ka mood score **thoda boost** (positive) bhi hoga — taaki similar mood wale gaane thoda zyada aayein (opposite of skip-penalty)

---

## 11. Implementation Phases (jab ready ho, is order mein banega)

**Current implementation checkpoint:** Phase 1 tagging, Phase 2 data/session state, Phase 3 selection engine, Phase 4 language selection, and Phase 5 reel-style player are now present in the project. Phase 5 uses existing `audioHandler.playWithRetry()` and does not modify the protected playback pipeline.

1. **Tagging system** — ✅ DONE (`radio_tagging.dart`)
2. **Data layer** — ✅ DONE (2026-09-17): `radio_history_store.dart`
   (SharedPreferences-backed `radio_history`, 150-din purge, non-repeat
   lookup + oldest-fallback helpers) + `radio_service.dart` (session-only
   mood scores — skip-penalty/decay/escalation formula section 4, favorite
   boost section 10, `selectedLanguages` session state section 3.3).
   Dono `main.dart` me wire kiye (`init()` app start pe, `RadioService`
   Provider me). Selection algorithm abhi nahi bana (Phase 3 ka kaam) —
   `effectiveScore()`/`wasPlayedRecently()` bas expose kiye hain jinhe
   Phase 3 (`radio_engine.dart`) consume karega.
3. **Selection algorithm** — pool building + scoring + weighted random pick (`radio_engine.dart` jaisa standalone file)
4. **Language Select Screen** — naya screen, multi-select UI
5. **Radio Player Screen** — reel-style UI, minimal controls, swipe gesture
6. **Skip/favorite wiring** — mood-decay aur boost logic connect karna
7. **☰ Reset menu** — confirm dialog + navigation
8. **Lyrics sync check + best-effort wiring** — source check karke implement
9. **Entry icon** — top bar mein naya icon add karna
10. Documentation: NOTES.md aur README.md mein naya section add (jaisa har part ke baad hota hai)

Har phase standalone naye files mein hoga jahan tak ho sake — existing protected files ko sirf minimal, additive hook-points ke liye touch kiya jayega (jaise existing play function ko normal call karna), koi core pipeline logic change nahi.

---

## 12. Open Questions (implement se pehle finalize karna)

- [ ] Lyrics source timed data deta hai ya nahi (check karna padega)
- [ ] Mood scores session-only rahein ya halka persist ho (light cross-session carry) — abhi tak decide: **session-only by default**
- [ ] "Previous" button — sirf last-played cache se ek gana peeche jaye, ya poori history navigate ho (recommend: sirf 1 gana peeche, simple)
- [ ] SKIP_PENALTY aur DECAY_CONSTANT exact values — tuning ke liye starting point diya gaya hai (15 points, 25-30 min), real usage ke baad adjust hoga

---

*Ye document sirf planning/roadmap hai. Implementation start karne ke liye explicitly bolna hoga.*

## Part 6 — Smart Local Playback Cache

- Last **15 non-favorite played songs** are retained in the local audio cache.
- The cache is **local-first** for Previous/replay: disk cache is checked before any fresh network resolve.
- When a cached song is played again, its `last_played` timestamp is refreshed so it stays in the 15-song rotation.
- Favorite/liked songs are marked **protected** and are not evicted by the 15-song rotation or normal cache cleanup.
- If a song is liked while it is currently playing, the background cache writer detects the liked state after the file is written and protects that cached file.
- The existing size ceiling remains as a secondary safety limit; protected favorites can remain even when the unprotected rotation is full.
- Cache failures never block playback; network playback continues normally when a local file is unavailable.

## Implementation Status — through Part 6

- Phase 1: Tagging system — implemented in `radio_tagging.dart`.
- Phase 2: Radio session/history data layer — implemented.
- Phase 3: Candidate selection engine — implemented in `radio_engine.dart`.
- Phase 4: Multi-language selection screen — implemented.
- Phase 5: Reel-style Radio Player — implemented.
- Phase 6: Smart local playback cache — implemented as an app-private local cache: last 15 non-favorite played songs rotate by LRU, while liked/favorite cached songs are protected and retained.
- Local-first playback checks DownloadDB/cache before fresh network resolution, so Previous/replay can use the local file without another stream resolve when the file is ready.
- Radio-specific recommendation logic does not use audio pre-download as a selection mechanism; the Part 6 cache is a playback reliability layer requested for fast Previous/replay.



## Part 7 — Radio Reset & Change Language

Implemented from the Radio Mode roadmap phase 7.

- Added a top-right ☰ Radio menu with only **Reset & Change Language**.
- Confirmation dialog warns that the Radio session/mood state will reset while saved language selections remain.
- Confirm clears temporary mood state, pauses Radio playback, and returns to the Language Select screen.
- Language Select reloads the persisted selection, so previous choices remain pre-ticked.
- Radio queue/candidate state is discarded by leaving the player; no protected playback/resolve/CDN pipeline was modified.
- Part 6 cache behavior remains intact: recent-play cache and favorite protection are not cleared by Radio reset.


## Part 8 — Lyrics Sync (2026-09-17)

**Status: DONE.** The existing lyrics source was inspected before implementation. `LyricsService` already fetches LRC-style timed lyrics from lrclib.net, caches results locally, parses timestamped lines, and exposes plain lyrics as a fallback. Therefore Phase 8 reuses that service rather than adding another lyrics backend.

Implementation:
- Radio Player requests lyrics whenever the current Radio song changes.
- A compact synced subtitle strip is shown only when timed lyrics are available.
- The strip follows the existing `just_audio` position stream and highlights the active line while showing the next line when available.
- Lyrics network errors, missing lyrics, plain-only results, and parsing failures are fail-soft: Radio playback continues and the strip remains hidden.
- Existing full Lyrics screen behavior remains intact.
- Protected playback/resolve/CDN/background methods were not modified.

Phase status: 1-8 complete. Phase 9 (entry icon) remains as the next roadmap item.

## Implementation Status — Part 9

**Implemented:** Home top-bar Radio entry icon. The entry uses the existing `RadioLanguageSelectScreen` flow, includes tooltip/accessibility semantics, and does not alter protected playback/resolve/CDN/background methods. Documentation updated after completion.

## Phase 10 — Documentation (2026-09-17)

**Status: DONE.** Documentation has been updated after implementation of Phases 1–9.
- `NOTES.md` records the completed Radio Mode phases and the Part 6 cache behavior.
- `README.md` records the Part 10 status.
- `FEATURE_ROADMAP.md` records Phase 10 documentation completion.
- No runtime/protected playback pipeline changes were made in this documentation phase.

**Radio Mode implementation status: Phases 1–9 complete; Phase 10 documentation complete.**

## Part 11 — Radio Tuning & Open-Question Finalization (2026-09-17)

**Status: DONE.** The roadmap's remaining tuning choices were made explicit without changing the protected playback pipeline.

- Radio history/non-repeat window is fixed to **150 days** (5 months), which sits inside the original 4–6 month requirement.
- Mood scores remain **session-only by default**, matching the original roadmap decision.
- Previous remains **one-step history navigation**; it does not create a new non-repeat history record and relies on the existing local-first playback/cache path when available.
- Starting tuning remains `SKIP_PENALTY=15` and `DECAY_CONSTANT=27 minutes`; these are centralized constants and intentionally remain easy to tune later.
- Multi-language balancing and ~60/40 hits/latest remain soft preferences, not hard filters, so small candidate pools stay playable.

## Part 12 — Radio Transition Hardening (2026-09-17)

**Status: DONE.** Added defensive state handling around the Radio UI transitions.

- Auto-next, swipe-next, and Previous transitions are serialized with a transition guard.
- A rapid double swipe or a swipe while an automatic completion transition is running can no longer start overlapping Radio play transitions from the same screen.
- Completion callback ignores a second transition while one is already in progress.
- Failure paths release the transition guard in `finally`, so one failed resolve/play cannot permanently lock the Radio UI.
- No changes were made to the protected resolve/play/CDN/background pipeline.

**Radio Mode status: Parts 1–12 complete.**

## Radio — Post Part 3–12 Bug-Fix Audit (2026-09-17)

- Fixed Radio completion ownership: while `RadioPlayerScreen` is active, the global `AudioHandler` completion listener no longer advances the normal `QueueService`; Radio owns its own auto-next transition.
- Fixed Radio transition subscription lifecycle: the Radio completion listener is cancelled on screen dispose.
- Fixed mood-decay accounting: skip penalties are now stored separately from the base mood score, so even escalated penalties recover exponentially instead of permanently lowering the base score.
- Fixed multi-language eligibility: fresh/fallback selection is evaluated per language, so an exhausted language cannot disappear merely because another selected language still has fresh candidates.
- Improved hits/latest candidate sampling by shuffling within each bucket before applying the approximate 60/40 target.
- Fixed stale cache metadata: when a CacheDB row points to a missing audio file, the stale row is removed during local-cache lookup.
- Existing 15-song recent cache and favorite-protected cache behavior remains intact.
- Protected resolve/CDN pipeline remains unchanged apart from the additive Radio completion-ownership hook.

## Post-Implementation Hardening Audit — Parts 3–12

The original implementation roadmap ends at Phase 10; after implementation, a source audit identified and fixed these cross-phase issues:

1. **Completion ownership:** Radio Player owns end-of-track auto-next while active, so the global queue completion callback is suppressed for Radio.
2. **Transition listener lifecycle:** Radio's completion subscription is cancelled on dispose.
3. **Mood penalty recovery:** escalated skip penalties decay from a separate temporary penalty state rather than permanently mutating the base score.
4. **Per-language fallback:** each selected language gets its own fresh/fallback eligibility before the combined pool is scored.
5. **Candidate variety:** hits/latest buckets are shuffled before approximate 60/40 sampling.
6. **Stale cache rows:** missing cache files are removed from CacheDB during lookup.

These are hardening fixes; the protected playback/resolve/CDN pipeline remains otherwise unchanged.

## Radio — v78 Bug-Fix Batch (2026-09-18, user-reported)

Three separate user-confirmed bugs, all in `radio_player_screen.dart`:

1. **Skip/Previous button stuck disabled after the 1st transition.**
   `_advance()` and `_previous()` both flip a `_transitioning` bool to
   control the skip button's enabled/disabled + color state. Setting it
   to `true` self-corrected visually (a `setState()` happened moments
   later for an unrelated reason), but setting it back to `false` inside
   each function's `finally` block was a bare field assignment with NO
   `setState()` call anywhere after it in that code path. Result: from
   the 2nd song onward, the skip button rendered permanently grey/
   disabled even though the underlying flag was already `false` and a
   skip would have worked if the button could be tapped. Fixed by
   wrapping all four `_transitioning` assignments in `setState()`
   (guarded with `mounted` checks in the `finally` blocks, since the
   screen could be disposed mid-transition).

2. **Vertical swipe (next/previous) only worked over the title/lyrics
   area, not over the seekbar or buttons.** The `GestureDetector` for
   swipe-up/down was previously scoped to a single `Expanded` region
   inside `_buildContent()` (topBar through lyrics) — deliberately
   excluding the progress bar and control-button row so the seekbar's
   own horizontal drag wouldn't compete with it. Per user feedback, the
   caption/lyrics area is purely decorative ("dekhne ka hai, kaam ka
   nahi") and the swipe should work across the *entire* screen instead.
   Moved the `GestureDetector` up to wrap the whole `Stack` in `build()`
   (artwork + content + controls, all of it). Vertical-drag and the
   seekbar's horizontal-drag are different gesture axes and don't
   compete in Flutter's gesture arena, so this doesn't affect seeking or
   button taps.

3. **Lyrics sync lagged up to ~1 second behind the normal (non-Radio)
   Lyrics screen.** `RadioLyrics` used a 1-second repeating
   `AnimationController` as a polling ticker to decide which lyric line
   should be highlighted — so a line change could be visible up to a
   full second late. The regular `lyrics_screen.dart` instead reacts
   directly to `player.positionStream` (updates on every emitted
   position, no polling delay). Switched `RadioLyrics` to the same
   approach: subscribes to `positionStream` directly and dropped the
   `AnimationController`/`SingleTickerProviderStateMixin` entirely. Sync
   should now feel as immediate as the normal Lyrics screen.

**Still not done in this batch (flagged, not fixed):** the one visible
on-screen button (tooltip "Next song", positioned to the left of Play)
is still labeled/positioned in a way that looks like "Previous" but
behaves as "Next" — left as-is since navigation is now swipe-driven per
user direction and they did not ask for this button to be touched.

**Not verified on-device** (no Flutter toolchain/network in this
environment) — brace/paren balance and structural review done by hand,
but an actual `flutter build`/on-device swipe + skip-button + lyrics
test is still needed.
