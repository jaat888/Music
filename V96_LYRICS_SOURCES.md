# V96 — 3 naye lyrics sources add kiye (user request)

User ne 3 naye lyrics sources maange: YouTube Music internal, BetterLyrics,
aur Kugou. Priority order user ne khud di: **YT Music -> BetterLyrics ->
LRCLIB -> Kugou** (Kugou ki exact jagah Claude ki apni choice thi, user ne
"apne se dekh le" bola). Dono modes (LyricsScreen + Radio) automatically
cover ho gaye kyunki dono `lyrics_service.dart` ka wahi shared
`getForSong()`/`prefetchForSongs()` use karte hain — koi alag wiring nahi
chahiye thi.

## Naye sources — kaise kaam karte hain

1. **YouTube Music internal** (`lib/services/innertube_client.dart` —
   naya `getLyrics(videoId)` method) — wahi public/undocumented InnerTube
   flow jo `ytmusicapi` (Python) bhi use karta hai: `next` call se is
   video ke "Lyrics" tab ka `browseId` nikalo, phir `browse` call se
   `musicDescriptionShelfRenderer.description.runs` hi lyrics text hota
   hai. **PLAIN-TEXT ONLY** — YouTube Music ka apna real-time
   word-highlight wala synced mode is public endpoint se available nahi
   hai (ytmusicapi bhi nahi de paata). Koi extra API key nahi chahiye,
   InnertubeClient ka existing `_post()`/context/self-heal sab reuse
   hota hai.

2. **BetterLyrics** (`https://lyrics-api.boidu.dev/getLyrics?s=&a=&d=`) —
   TTML (Apple Music format) response, syllable/word-level timing.
   `_parseTtml()` naya regex-based parser likha (xml package add nahi
   kiya — is TTML shape ke liye zaroorat nahi thi) jo har `<p begin="">`
   ko ek LyricLine banata hai (uske andar ke saare `<span>` words ka text
   jod ke). **Note:** hamara `LyricLine` model sirf line-level hai,
   per-word timing store nahi karta — isliye "word-by-word karaoke"
   effect abhi nahi milega, sirf line-by-line sync (LRCLIB jaisa hi
   quality ka result, bas ek extra source). Agar aage word-level karaoke
   chahiye to `LyricLine` ko `List<({String word, Duration begin})>`
   jaisa kuch banana padega + `lyrics_screen.dart` ki UI badalni padegi —
   ye is batch me NAHI kiya gaya.

3. **Kugou** (`mobileservice.kugou.com` search -> `lyrics.kugou.com/download`)
   — 2-step: search by `"{artist} - {title}"` keyword + duration ->
   candidates list (id + accesskey) -> download by id/accesskey ->
   base64-encoded LRC text (`content` field) -> decode -> existing
   `_parseLrc()` reuse. Duration-closest candidate select karta hai jab
   multiple aa jaayein (covers/remixes).

## Priority logic (`_fetchMultiSource`)

Purana pattern hi follow kiya: koi bhi source **SYNCED** de de to turant
wahi return ho jaata hai (best experience). Agar sirf **PLAIN** mile to
usko fallback ki tarah rakha jaata hai aur neeche wale sources try hote
rehte hain (shayad unme se koi synced de de) — plain candidates me se
sabse PEHLA mila (user ke priority order ke hisaab se) hi final fallback
banta hai. Naya order: YT Music (plain) -> BetterLyrics (synced/plain) ->
LRCLIB exact -> LRCLIB search -> Kugou (synced) -> JioSaavn (plain) ->
lyrics.ovh (plain).

Cache key `lyrics_v3_` se `lyrics_v4_` bump kiya (naya source-order purane
cache se conflict na kare).

## STATUS — compile-test nahi ho paaya

Is environment mein Flutter/Dart toolchain nahi hai, isliye manual
line-by-line review hi ho paaya (braces/imports/types sab check kiye).
Sabse zyada risky hissa:
- **Kugou** ka exact JSON shape (`candidates[].id`/`accesskey`,
  `content` field naam) — ye undocumented/reverse-engineered API hai,
  agar Kugou ne response shape badal diya ho to ye source silently
  `null` return karega (try/catch se wrapped hai, poora pipeline nahi
  girega, bas ye ek source skip ho jaayega).
- **YT Music internal** ka tab-title/browseId detection
  (`title.contains('lyrics')` ya `MPLYt` prefix) — agar kisi gaane pe
  "Lyrics" tab hi nahi hai (bahut se gaanon pe nahi hota), to ye source
  cleanly `null` deta hai, error nahi.
- **BetterLyrics** rate-limit: bina `X-API-Key` ke sirf cached queries
  reliably kaam karenge, naye/rare gaanon pe kabhi-kabhi 429 aa sakta hai
  — us case me bhi `null` return hoke agla source try hota hai.

Real device pe test karke dekhna: kaunsa source zyada Hindi/Haryanvi/
Punjabi gaano pe hit deta hai, aur kya Kugou/BetterLyrics genuinely kaam
kar rahe hain ya hamesha skip ho rahe hain (log me `source:` field
dekhkar pata chal jaayega — cached result me bhi save hota hai).
