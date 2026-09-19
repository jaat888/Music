# V120 — JioSaavn playlists Home me dikhti nahi thi

## Root cause
`jiosaavn_service.dart` sirf `jiosaavn.com/api.php` ka purana shape try karta
tha (bina `api_version=4`). Us shape me playlist ka naam `listname` me aata hai,
lekin parser sirf `title`/`name` dekhta tha -> har item "title nahi mila" maan
ke skip -> khaali list -> Home ka "India ki Playlists" section chup-chaap gayab
(fail ko koi error/log bhi nahi dikhta tha).

## Fix
- 3 sources, ek ke baad ek: (1) jiosaavn.com `api_version=4`, (2) jiosaavn.com
  legacy, (3) saavn.dev fallback. Browser-jaise headers. Ek source baar-baar fail
  ho to 2 min skip (Home atke nahi).
- Parser: title/name/listname, id/listid/token, image string ya list, artists
  (singers / primary_artists / more_info.artistMap / artists.primary / subtitle),
  HTML entities (&quot; &amp; &#039;) clean.
- `getPlaylistTracks` bhi teeno shapes; saavn.dev wali playlists `sd:` prefix
  se pehchani jaati hain.
- Har failure AppLogger me `JIOSAAVN [...]` se likha jata hai (HTTP code /
  non-JSON / 0 parsed) — phir bhi na aaye to log me exact wajah milegi.
- Home: list 12 ghante disk cache, app khulte hi turant dikhti hai, fail hone par
  purani list rehti hai; pull-to-refresh force refresh; categories 5-5 parallel
  (pehle ek-ek karke, bahut slow).
- Naya test: `test/jiosaavn_service_parsing_test.dart` (teeno shapes).

Not run here (no Flutter SDK / no network in sandbox): live endpoints, flutter
analyze/test, device test. Agar phir bhi section na aaye to app log me
`JIOSAAVN` wali lines bhejna.
