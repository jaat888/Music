# V94 — code-review + real-device log fixes (flutter analyze/run nahi chala; padh ke + log se)

## Fix kiye
1. background_service.dart `playWithRetry()`: debounce Timer cancel hone par
   (naya playWithRetry ya `stop()`) purane call ka Completer kabhi complete nahi
   hota tha -> `await playWithRetry()` latak sakta tha. Ab `_cancelSkipDebounce()`
   Completer bhi complete karta hai + Timer callback me try/catch/finally.
2. radio_swipe_stage.dart: `onVerticalDragCancel` handler (gesture cancel pe screen
   aadhi khinchi atak jaati thi) + `_animateTo` me `_settleAnim=null`.
3. background_service.dart `_handleStreamDrop()`: ek hi asli failure ke liye do signal
   (playbackEventStream onError + `_playSong` catch) 10-100ms me aate the -> ek error
   2 retry gin leta tha aur do parallel retry-chains ek dusre ka setUrl cut karti thi
   (log: "retry 1/3" aur "retry 2/3" 9ms gap pe, ~10s ka atkna). Ab same token ke liye
   700ms ke andar dobara aaya call ignore hota hai.
4. background_service.dart `play()`: just_audio ka `player.play()` Future pause/stop/
   complete tak resolve nahi hota, isliye purana `.then(phase=playing)` PAUSE dabane par
   phase ko `playing` kar deta tha (log: `pause() DONE — phase=playing`) aur skip pe naye
   gaane ka phase overwrite karta tha. Ab resume hote hi (source ready ho to) turant
   phase set hota hai; play() ka Future caller ko latkata nahi.

## Secret / repo safai
- `env.json` hata diya (Spotify secret usme tha). CI `build.yml` GitHub Secrets se
  `--dart-define` deta hai, isliye build pe asar nahi. `env.json.example` rahega.
- `.gitignore` add (env.json, build/, .dart_tool/ ...).
- Copilot ki files (AGENTS.md, .devcontainer) hata di.

## Pata hai, abhi fix NAHI kiya
- `_playCandidate` superseded hone par `false` deta hai -> `_advance` use "failed" maan ke
  markFailed kar sakta hai.
- Radio `_upcoming` me log ke hisaab se hamesha sirf 1 gaana (prefetch "1 candidates").
- Mid-play buffering stall ka watchdog nahi.
- Prefetch batch-of-2 change: user ne abhi mana kiya tha.
