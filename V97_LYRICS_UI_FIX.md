# V97 — lyrics highlight/overflow fixes (2 screenshots se report)

User ne 2 screenshots bheje:
1. Radio screen (in-app overlay lyrics) — active line ka highlight
   (bada, green-ish/white, upar aata hai) achha lagta hai, lekin jab line
   **lambi** ho to **cut ho jaati hai**.
2. Full LyricsScreen — subtitle ke neeche ek **bahut bada khaali gap**,
   aur **live highlight (current-line) dikhta hi nahi** — "screen ke size
   ke hisab se set nahi hota".

## Root causes + fix

### 1. Radio overlay (`radio_player_screen.dart` — `RadioLyrics`)
`ListView.builder` ka `itemExtent: 40` fixed tha, lekin active line
2 lines tak wrap ho sakti hai (font 17, height 1.18) — do lines ka
combined height ~40px hi banta hai, yaani BILKUL bhi margin nahi tha.
Thoda bhi extra letter-height/shadow padding lagte hi text apni 40px ki
slot se bahar chala jaata (neighbour line ke upar overlap/cut).
**Fix:** `itemExtent` 40 -> 56 (2-line active text ke liye comfortable
margin), `_centerActive()` ka matching constant bhi 56 kiya (warna
centering scroll galat ho jaata), padding thoda adjust (68->60).

### 2. Full LyricsScreen (`lyrics_screen.dart` — `_buildSyncedLyrics`)
Do cheezein independently, bina ek dusre se match kiye, "viewport height"
maan rahi thi:
- `ListView`'s top/bottom **padding** = `MediaQuery.of(context).size.height
  / 3` — ye **POORA SCREEN height** hai, jabki ye list Column ke andar
  `Expanded` me hai — AppBar + album art + title/artist upar pehle se
  kaafi jagah le chuke hote hain, isliye list ka ASLI available height
  poore screen se kaafi kam hota hai. Isi wajah se top pe zaroorat se
  bahut zyada khaali gap dikh raha tha (screenshot #2 ka bada blank area).
- `_maybeAutoScroll()` ka scroll-target formula
  `_scrollController.position.viewportDimension` (list ka ASLI/sahi
  height) use karta tha — ye do values (padding vs scroll-target) EK
  DUSRE SE MATCH nahi karte the. Result: jab active line change hoti,
  scroll wahan jaata jahan us mismatch ke hisaab se "sahi" lagta, jo
  actual visible area se bahar hota — **highlighted line kabhi screen pe
  dikhti hi nahi thi**.

**Fix:** `LayoutBuilder` se is Expanded ka ASLI available height
(`constraints.maxHeight`) liya, aur ab padding (`viewportHeight/2 -
lineHeight/2`) aur scroll-target dono **isi ek hi height source** se
derive hote hain — hamesha match karenge, chahe screen/device/AppBar
height kuch bhi ho. `_maybeAutoScroll()` ab `viewportHeight` param leta
hai (pehle apna khud ka `viewportDimension` use karta tha, jo mismatch ki
jadd thi).

## STATUS — compile-test nahi ho paaya
Is environment mein Flutter/Dart toolchain nahi hai. Manual review kiya
(braces, param signatures, sab call sites match kiye). Real device pe
dekhna: Radio me ek genuinely lambi line pe ruk ke check karna (cut to
nahi ho rahi), aur full LyricsScreen khol ke dekhna ki highlight ab
visible hai aur upar wala khaali gap normal lag raha hai.
