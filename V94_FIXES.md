# V94 — code-review fixes (flutter analyze/run nahi chala, sirf padh ke)

1. background_service.dart `playWithRetry()`: debounce Timer cancel hone par
   (naya playWithRetry ya `stop()`) purane call ka Completer kabhi complete nahi
   hota tha -> `await playWithRetry()` hamesha latka rehta tha (Radio me
   `_advance` ka `finally` na chalne se `_transitioning` stuck ho sakta tha).
   Ab `_cancelSkipDebounce()` Completer bhi complete karta hai, aur Timer callback
   me try/catch/finally hai taaki unexpected exception pe bhi caller na latke.
2. radio_swipe_stage.dart: `onVerticalDragCancel` handler add (gesture cancel pe
   screen aadhi khinchi atak jaati thi) + `_animateTo` me `_settleAnim=null`
   (purani anim ka listener reset() pe `_drag` ko purani value pe kudata tha).

## Pata hai, abhi fix NAHI kiya
- `_waitUntilPlaying()` / `_playWithRecovery`: `player.playing` play() call hote hi
  true ho jaata hai (buffering me bhi) -> "playing" ka matlab "awaaz aa rahi hai" nahi.
  Mid-play buffering stall ka koi watchdog nahi hai.
- `_playCandidate` superseded hone par `false` return karta hai -> `_advance` usse
  "failed" maan ke markFailed kar deta hai (gaana galat block ho sakta hai).
- `_onRadioPlaybackError` ka `_ensureRecovery(autoAdvanceOnFailure:true)` aur
  `_advance` ke andar wala `_ensureRecovery` overlap kar sakte hain -> ek extra skip.
- Prefetch batch-of-2 change: tumne bola tha abhi mat karo, isliye chheda nahi.
