# V119 — iTunes playlist ab har baar reload nahi hoti

## Problem
V116 me iTunes chart ka *list* (title+artist) daily cache hota tha, lekin
`CuratedPlaylistScreen` har baar playlist kholne par saare 50 gaane YouTube pe
ek-ek karke dobara search karta tha ("Match kar rahe hain 1/50 ...") — isliye
playlist har baar naye sire se load hoti thi.

## Fix
- Naya `lib/services/curated_match_cache.dart`: title+artist -> matched YouTube
  song ka persistent cache (SharedPreferences, 45 din, max 500 entries).
- `curated_playlist_screen.dart`: pehle cache dekhta hai; sirf uncached gaano
  ke liye YouTube search hota hai. Naya match turant disk pe save (har 5 pe +
  end me). Match fail hone wale gaane cache nahi hote (agli baar retry).
  JioSaavn playlists bhi isi se fast hoti hain.
- `home_screen.dart`: `_loadItunesChart()` ab loading flag sirf tab set karta
  hai jab list khaali ho — pehle chart card tap/refresh par kuch der gayab ho
  jata tha.
- Naya test: `test/curated_match_cache_test.dart`.

Pehli baar (ya chart me naya gaana aane par) sirf naye gaano ka matching hoga;
uske baad playlist instantly khulti hai.

Not run here (no Flutter SDK): `flutter analyze`, `flutter test`, device test.
