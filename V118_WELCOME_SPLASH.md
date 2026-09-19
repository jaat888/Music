# V118 — "Welcome to SurSathi" intro (voice + synced animation)

- Har baar app khulne par intro chalta hai (pehle sirf pehli baar wala splash tha).
  `main.dart` -> `_Boot` ab seedha `SplashScreen` dikhata hai; splash ke baad
  `onboarding_done` check karke Home / Onboarding khulta hai (logic wahi).
- `assets/audio/welcome.mp3` (ElevenLabs female voice, 2.04s). `pubspec.yaml` me
  `assets: - assets/audio/` enable kiya.
- `lib/screens/splash_screen.dart` — poori tarah naya:
  - Voice ke exact onsets (Wel 0.08, come 0.40, to 0.67, Sur 0.90, Sa 1.19,
    thi 1.41, end 1.64 sec) mp3 se measure kiye; har shabd/syllable apne
    onset par screen pe aata hai.
  - Waveform bars asli voice loudness envelope (`_kEnv`, 20 ms steps) se chalte
    hain; logo ka glow/scale bhi voice ke saath pulse karta hai; ripple rings
    "Wel", "Sur", "thi" ke beat par.
  - Sync: audio + font ready hone tak (max 0.9s) ruk ke controller aur voice
    ek saath start; voice logo-pop ke 0.25s baad, output latency (0.08s) ke
    hisaab se pehle trigger. Constants: `_kLeadIn`, `_kOutputLatency`.
  - Total ~2.6s, tap se skip. Audio fail ho to silent animation, app normal.
- Sync thoda aage/peeche lage to sirf `_kOutputLatency` (0.08) badlo — bada karne
  se awaaz pehle trigger hogi.

Not run here (no Flutter SDK in sandbox): `flutter analyze`, build, device test.
