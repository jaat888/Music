## V113 (2026-09-19) — Deep playback-race hardening + Radio completion/history safety

V112/V111 ke static re-scan me kuch residual race conditions mile. Is build me
unhe alag-alag patch kiya gaya hai. Goal ye hai ki **purane async result ko
naye gaane ki state par likhne ka chance minimum ho**, bina proven playback
pipeline ko unnecessarily rewrite kiye.

### 1) Timed-out `setUrl()` / `setAudioSource()` handle ab lost nahi hota
**File:** `lib/services/background_service.dart`

**Bug:** Dart ka `Future.timeout()` sirf caller ka `await` timeout karta hai;
underlying just_audio/native prepare zaroori nahi ki usi waqt cancel ho. Purane
code me timeout ke `finally` me `_activeSetUrlOperation = null` ho jaata tha.
Isliye next retry ko pata hi nahi hota tha ki purana native prepare abhi
zinda ho sakta hai.

**Fix:** operation reference ab tabhi clear hota hai jab original Future
actually success/error ke saath complete hota hai. Timeout par reference
retain hota hai; next source replacement `_abortInFlightSetUrl()` ke through
`player.stop()` karke short unwind window deta hai.

**Kyun:** late native completion ko current retry ke saath compete karne se
rokna aur stale prepare ko trackable rakhna.

### 2) Global playback-error ko healthy current playback par apply hone se rokna
**File:** `lib/services/background_service.dart`

**Bug:** `playbackEventStream.onError` source-id ke saath error nahi deta.
Song A ka delayed error Song B ke start hone ke baad aa sakta tha; sirf token
check se ise 100% identify nahi kiya ja sakta.

**Fix:** source-switch settle window ke saath ab actual `positionStream`
progress bhi track hota hai. Agar current token ki playback genuinely start
ho chuki hai aur position abhi recently advance hui hai, delayed error ko
stale maana jaata hai aur recovery trigger nahi hoti. Genuine current-source
drop me position progress rukti hai, isliye recovery path available rehta hai.

**Kyun:** fixed delay se stronger evidence-based guard; smooth playback ko
late old-source error se restart/glitch hone se bachana.

### 3) `durationStream` stale duration guard
**File:** `lib/services/background_service.dart`

**Bug:** shared player ka `durationStream` source id nahi deta. Purane song ka
delayed duration naye `MediaItem` par lag sakta tha.

**Fix:** duration update ko current `_playToken`, current Song id aur current
`MediaItem.id` se bind kiya gaya.

**Kyun:** notification/lock-screen/seekbar me purane gaane ka duration naye
gaane par overwrite na ho.

### 4) Radio `completed` event ki candidate identity harden
**File:** `lib/screens/radio_player_screen.dart`

**Bug:** Radio completion listener global `ProcessingState.completed` sunta
hai. Sirf "near end" + old start timestamp se same shared player par late
completion ko current candidate ka completion samajhne ka residual chance tha.

**Fix:** har Radio candidate transition par purani completion identity clear
hotii hai. Successful start ke baad Song id + candidate-generation + start
time bind hote hain. `completed` tabhi auto-advance karega jab tino current
candidate se match karein aur real duration available ho aur position end ke
paas ho.

**Kyun:** stale completion se Radio ka achanak unwanted Next/skip band karna.

### 5) `RadioHistoryStore.init()` concurrent-call safe
**File:** `lib/services/radio_history_store.dart`

**Bug:** pehle `_initialized` true hone se pehle do callers ek saath `init()`
chala sakte the.

**Fix:** shared `_initFuture` single-flight initialization use karta hai.

**Kyun:** ek hi history load/purge pipeline chale aur parallel callers same
result await karein.

### 6) Radio history writes serialize
**File:** `lib/services/radio_history_store.dart`

**Bug:** record/skip/replay/purge ki async SharedPreferences writes overlap kar
sakti thi. Ek older snapshot late finish karke newer write ko overwrite kar
sakta tha.

**Fix:** `_writeTail` FIFO persistence chain. JSON snapshot queue ke andar
banaya jaata hai, isliye queued writes stale pre-queue snapshot nahi likhti.

**Kyun:** rapid Next/skip/replay events me learning history lose na ho.

### 7) V109 learning fixes preserve kiye gaye
`recentArtistCounts()` abhi bhi Radio ranking me persisted 45-minute history
+ current-session tail ke saath wired hai. `tagAffinity`/`artistAffinity`
skipped rows ko separately `tagSkipTimingAffinity`/
`artistSkipTimingAffinity` se double-count nahi karte.

### 8) Release signing note
Debug keystore ko fake production-release signing se replace nahi kiya gaya,
kyunki project me private release keystore/credentials nahi hain. Is build me
is limitation ko document kiya gaya hai; real release ke liye developer-owned
keystore configure karna hoga.

### Validation
Static source inspection + targeted unit test added. Flutter SDK/device
runtime is environment me available nahi tha, isliye APK/device playback test
claim nahi kiya gaya.

