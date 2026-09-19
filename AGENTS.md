# SurSathi — Copilot Agent instructions (AGENTS.md)

Ye ek Flutter (Android) music/radio app hai. Repo mein `android/` scaffold
adhura hota hai; Codespace ban'ne par `flutter create . --platforms=android
--org com.sursathi --project-name sursathi --no-overwrite` already chal chuka hota hai.

## Kaam ka tareeka
1. `flutter pub get`
2. `flutter analyze` — saari errors/warnings fix karo (lib/ aur test/ dono)
3. `flutter test` — jo fail ho use fix karo (test ko dabakar nahi, asli bug fix karke)
4. `flutter build apk --debug --dart-define=SPOTIFY_CLIENT_ID=x --dart-define=SPOTIFY_CLIENT_SECRET=x`
   — build errors fix karo, dobara build karo, jab tak pass na ho.
5. Code padhkar (khaaskar lib/services/background_service.dart, radio_engine.dart,
   radio_service.dart, lib/screens/radio_player_screen.dart) race conditions,
   missing timeouts, stuck locks (jaise `_transitioning`), unawaited futures,
   null-safety crashes dhoondo aur fix karo.
6. Har fix ke baad 2-5 dobara chalao. Ant mein batao: kya bug tha, kahan, kya fix kiya.

## Rules
- Emulator Codespaces mein nahi chalta — runtime bugs code-reading + tests se dhoondo,
  aur jahan test likha ja sake wahan naya test add karo.
- Existing behavior mat todo; chhote, focused changes karo. Bade refactor se pehle poochho.
- `env.json` / secrets kabhi commit ya print mat karo.
- `NOTES.md` aur V*.md files mein history hai — padh lo, dobara wahi galti mat karo.
- Kaam khatam hone par ek chhota `V94_*.md` note likho (repo ka purana style).

## Pehle ye padho
- `V94_FIXES.md` — usme "Pata hai, abhi fix NAHI kiya" wali list hai; un bugs ko bhi dekho aur fix karo (prefetch batch-of-2 change ko chhodo, user ne mana kiya hai).
