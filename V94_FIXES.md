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
- Prefetch batch-of-2 change: user ne abhi mana kiya tha.

## v103 mein fix hua
- Global `onError` stale-source race: `_handleStreamDrop()` hamesha CURRENT
  `_playToken`/current song padhta hai, lekin async `onError` kabhi bhi PURANE
  (abhi-abhi replace kiye gaye) source ka delayed signal ho sakta hai — token
  tab tak naye gaane ka ho chuka hota hai, isliye purana error naye (bilkul
  theek chal rahe) gaane par galat retry/restart trigger kar sakta tha. 700ms
  duplicate-guard isse nahi pakadta (wo sirf SAME token ke liye hai). Fix:
  `_lastSourceSwitchAt` timestamp — har naye setUrl/setFilePath attempt ke
  start pe record hota hai; ~1.8s ki settle-window ke andar aaya koi bhi
  `onError` ab silently discard hota hai (stale/purane-source signal maan ke).
- Mid-play buffering stall ka watchdog: `background_service.dart` me
  `_armStallWatchdog`/`_disarmStallWatchdog` — agar playback genuinely shuru ho
  chuka ho aur player koi throw-able error ke bina hi `ProcessingState.buffering`
  me 8 sec se zyada atka reh jaaye (silent CDN/network stall, koi `onError` nahi),
  to ab isko bhi ek stream-drop maan ke maujooda `_handleStreamDrop()` retry/give-up
  path trigger hota hai. Pehle aisa stall kabhi resolve hi nahi hota tha — audio
  hamesha ke liye ruka reh jaata, na retry na error UI.
- `stop()` ab `pause()` ki tarah `_userPaused = true` set karta hai, taaki Stop ke
  turant baad koi late/stray stream error silently ignore ho (pehle sirf `_playToken`
  bump hota tha, isliye kabhi-kabhi Stop ke thodi der baad audio khud-ba-khud
  resume ho jaata tha).
- Auto-advance-on-`completed` listener (`processingStateStream`) — poori file mein
  YE AKELA reactive native-stream listener tha jiske paas koi staleness-guard nahi
  tha (harr doosri jagah token/`_playbackStartedToken` check hoti hai). `.timeout()`
  underlying native setUrl/setAudioSource operation ko cancel nahi karta (dekho
  `_setUrlGeneration` ka comment) — ek abandoned/timed-out attempt ka late `completed`
  event is listener ko current (bilkul theek chal raha) gaana khatam hua maan ke
  galat skip/pause karwa sakta tha. Fix: ab sirf tabhi trust karta hai jab CURRENT
  token ki playback genuinely confirm-start ho chuki ho (`_playbackStartedToken ==
  _playToken`), warna stale/zombie signal maan ke ignore karta hai.

## Residual architecture note
`.timeout()` (setUrl/setAudioSource par) sirf Dart-side `await` fail karta hai —
underlying native operation SHARED `player` instance pe apni marzi se baad mein
bhi chal/complete ho sakta hai (just_audio is level ka true cancellation expose
nahi karta). `_setUrlGeneration` + `_lastSourceSwitchAt` + `_playbackStartedToken`
guards (upar) ab is file ke HAR reactive listener/continuation ko is race se bachate
hain — lekin ye sab mitigation hain, ek asli "cancel the native op" nahi. Agar future
mein bhi kabhi koi naya listener/reactive path add ho, use bhi yahi teeno guards me
se jo applicable ho zaroor lagayein.
