# V93 — Radio mode: Reels/Shorts-jaisa live swipe

## Kya badla

Pehle Radio ka swipe-up/down sirf **release** par fire hota tha — finger
jab tak screen pe hai tab tak screen bilkul move nahi hoti thi, aur jab
uthta tha to seedha agla gaana ek chhoti (0.12 offset) crossfade ke saath
aa jaata tha.

Ab naya `lib/widgets/radio_swipe_stage.dart` widget poori screen ko
**finger ke saath real-time follow** karta hai — jaisa Instagram Reels /
YouTube Shorts mein hota hai:

- Finger jitna khincho, screen utni hi live move karti hai (halke
  scale/dim depth effect ke saath).
- Agla/pichla gaana (Radio ke apne `_upcoming` / `_playedStack` se, jo
  pehle se hi prefetch + artwork-cached hote hain) turant ek halka
  preview card ke roop mein slide-in hota hai — kisi network wait ki
  zaroorat nahi.
- ~22% screen height khinchne par (ya tez fling se) commit ho jaata hai
  aur turant snap-through; kam khincho to spring-back, koi navigation
  nahi.
- Commit hote hi asli purana `_advance()`/`_previous()` logic (network +
  audio, retries, recovery — sab jo pehle se tha) turant fire hota hai,
  bilkul chheda nahi gaya.

## Kaise kaam karta hai (thodi detail)

- `radio_player_screen.dart` mein purana manual `GestureDetector` (jo
  sirf `onVerticalDragEnd` pe kaam karta tha) hata diya gaya — ab
  `RadioSwipeStage` poori screen ke around hai.
- Do naye chhote helper: `_peekNext()` (= `_upcoming.first`) aur
  `_peekPrevious()` (= `_playedStack.last`) — ye EXACTLY wahi candidate
  return karte hain jo `_advance()`/`_previous()` khud uthate hain, isliye
  preview hamesha accurate hota hai.
- `_buildPeekPage()` ek halka preview-page banata hai (sirf artwork +
  title/artist/language + chhota spinner) — controls/timeline/lyrics
  isme nahi hote (wo sirf asli "current" candidate se judi hoti hain).
- Commit hone ke baad, jab tak asli gaana load ho ke `_current` badal na
  jaaye, peek "parked" (poori screen dhaki hui) rehta hai — taaki purana
  gaana ulta flash na ho. Jaise hi asli switch hota hai, drag silently
  0 pe reset ho jaata hai (dono frames identical dikhte hain, koi jump
  nahi). Agar kisi wajah se 9 second tak switch na ho (jaise saare 12
  attempts fail ho jayein), safety-timeout khud spring-back kar deta hai
  taaki screen hamesha ke liye atki na rahe aur error dikh sake.
- Non-drag navigation (auto-advance jab gaana khatam ho, media
  notification ka next/prev, pending-nav drain) abhi bhi purani hi
  chhoti crossfade use karti hai (`_buildContent()` ke andar wala
  `AnimatedSwitcher`) — usko thoda aur polish kiya gaya hai (bada
  offset + halka scale-in), lekin wo poore-screen wala drag-swipe nahi
  hai, sirf crossfade hai (jaisa pehle tha, thoda behtar).

## Tune karne ke liye (agar feel adjust karni ho)

`lib/widgets/radio_swipe_stage.dart` ke top-level constants:
- `_commitFraction` (default `0.22`) — kitna % screen height khinchne par
  commit ho. Kam karoge to swipe "halka" lagega, zyada karoge to "bhaari".
- `_commitVelocity` (default `900.0`) — kitni fast fling commit karegi
  bina poora khinche.
- `_pendingSafetyTimeout` (default `9s`) — worst-case wait before
  auto-revert agar naya gaana load hi na ho paaye.

## Test karne layak cheezein (cloud IDE build ke baad)

1. Halka swipe (threshold se kam) → spring-back, gaana wahi rahe.
2. Poora swipe-up → agla gaana turant preview dikhe, phir seamlessly
   asli gaana ban jaaye (koi flash/jump na ho).
3. Poora swipe-down (pehla gaana ho to) → resistance mehsoos ho, koi
   navigation na ho.
4. Bahut jaldi-jaldi 2-3 baar swipe-up karo → koi crash/double-skip na
   ho (existing debounce/queue logic abhi bhi intact hai).
5. Seekbar drag (horizontal) aur play/pause/heart button taps — pehle
   jaisa hi normal kaam karein, swipe se conflict na ho.
6. Kharaab/slow internet par swipe-up karke dekho — parked preview par
   spinner dikhna chahiye, aur agar bahut der ho jaaye to khud-ba-khud
   wapas asli state par aa jaana chahiye.
