# SurSathi v106 — Radio effective-start signal + real shuffle

Scope: sirf list ke pehle 3 items. Item 4 (radio/search singleton continuation
state) aur item 5 (Android completeness + release signing) abhi BAAKI hain.

## 1. Radio recovery -> `playbackStarted` / position-latch

Pehle `radio_player_screen.dart` ka `_playWithRecovery()` aur `_ensureRecovery()`
"started" tab maante the jab raw `player.playing == true` ya
`playingStream.where(playing).first` 6s ke andar aaye. ExoPlayer hand-off mein
`playing` chhoti der `false` publish kar sakta hai, jabki source READY tha aur
position aage badh rahi thi — valid start "failed candidate" ban jaata tha
(markFailed + agla candidate / 8-retry loop).

Ab:
- `AudioHandler.waitForEffectiveStart({timeout})` (naya, additive): CURRENT
  `_playToken` ke liye `playbackStarted` (latch) YA position-advance-while-READY
  (>150ms) milte hi `true`, latch set karta hai. Request supersede ho jaaye
  (`_playToken` badla) to `false`.
- `_playWithRecovery()` aur `_ensureRecovery()` dono isi ko use karte hain
  (aur wait ke BAAD staleness re-check — user Next/Prev kar chuka ho to result
  discard).

## 2. Radio `_togglePlay()` = icon = same effective signal

v100 ne `_togglePlay()` ko `playbackStarted` pe daala, lekin icon abhi bhi
`rawPlaying || playbackStarted || (ready && position>250ms)` se decide hota
tha. Do signals alag -> hand-off gap mein icon "Pause", tap => `play()`.

Ab ek hi getter: `AudioHandler.effectivelyPlaying` — icon, `onTap` (live read,
build-time snapshot nahi) aur `_togglePlay()` teeno isi se.

**Side-bug jo isi mein mila:** purane icon-signal ka `ready && position>250ms`
fallback `_userPaused` check nahi karta tha. Paused player bhi READY rehta hai
aur position >250ms hoti hai => paused Radio gaane pe bhi icon "Pause" dikhta.
`effectivelyPlaying` mein `_userPaused` guard hai.

## 3. Shuffle ab `_shuffleOrder` se chalta hai

`QueueService._shuffleOrder` pehle bani thi lekin `next()/previous()/upcoming`
kahin use nahi karte the — `setShuffle(true)` ka koi asar nahi tha (screens
`list.shuffle()` karke queue bhejti thi, bas wahi "shuffle" tha).

Ab (shuffle ON):
- `_shuffleOrder` = play order (permutation of queue indices). `_queue` khud
  shuffle nahi hoti => shuffle OFF karte hi original order wapas.
- Toggle ON: current song order mein sabse pehle (jump nahi), baaki random.
- `next()/previous()` order mein chalte hain; repeat-off pe order ke end pe ruk
  jaata hai; repeat-all pe naya cycle (jo gaana abhi khatam hua wahi pehle nahi).
- `upcoming` + naya `upcomingIndices` play order mein; `isLastInPlayOrder` naya
  (background_service `skipToNext` ka "last + repeat off => stop" check ab
  `currentIndex == length-1` nahi).
- Order incrementally maintain hota hai: `add/addAll/radio refill` naye gaane
  order ke END mein (Up Next reshuffle nahi hota), `removeAt`, physical
  `reorder`, `jumpTo` (chuna gaana current ke turant baad, taaki previous() us
  gaane pe jaaye jo abhi baj raha tha).
- Queue screen: `reorderUpcoming()` (shuffle ON mein sirf play order badalta
  hai) aur `upcomingIndices[i]` (pehle `currentIndex + 1 + i` — shuffle mein
  galat hota).
- Purane call-sites (`list.shuffle(); setShuffle(true); setQueue(...)`) bina
  badle chalte hain (random start ke liye pre-shuffle useful hai).

Behavior note: shuffle flag app session bhar persist rehta hai (jaise pehle) —
lekin ab uska asar hota hai. Album "Shuffle" dabane ke baad koi aur list play
karoge to bhi shuffle ON rahega jab tak full player mein OFF na karo.

## Tests
`test/queue_service_shuffle_test.dart` (naya) — `flutter test`. Shuffle OFF ka
purana linear behavior bhi cover hai.

## Files
- lib/services/queue_service.dart
- lib/services/background_service.dart (additive: `effectivelyPlaying`,
  `waitForEffectiveStart`; `skipToNext` mein 1 condition)
- lib/screens/radio_player_screen.dart
- lib/screens/queue_screen.dart
- test/queue_service_shuffle_test.dart

STATUS: Flutter/Dart toolchain is environment mein nahi hai — `flutter analyze`/
`flutter test`/build NAHI chala. Shuffle order-maintenance ka algorithm Python
mein port karke 300 random-op sequences + properties pe check kiya; Dart code
manual review + bracket-balance check hi hua. Pehle `flutter analyze` aur
`flutter test` chalao.

## Baaki (abhi nahi kiya)
4. Radio/search singleton continuation state -> per-operation.
   (Note: `QueueService._maybeRefillRadio()` ka `.then` bhi stale refill ko
   naye queue mein append kar sakta hai — `setQueue()` radio disable karta hai
   par in-flight future ko cancel nahi karta. Isi item mein generation-guard.)
5. Android project completeness + release signing.
