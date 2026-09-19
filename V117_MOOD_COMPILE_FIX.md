# V117 — Mood mode compile-error fix (CI `test` job failure)

## Root cause
`lib/screens/radio_player_screen.dart` → `_preferredCandidateSource()` (Mood mode)
declared a local function `eligible(...)` and then, in the same scope,
`final eligible = _candidates.where(eligible).toList();`.
Dart does not allow a local function and a local variable with the same name in
one scope (and the variable was also referenced inside its own initializer),
so the file failed to compile. `test/mood_catalog_test.dart` imports
`radio_language_select_screen.dart`, which imports `radio_player_screen.dart`,
so the test file failed at *loading* time
(`loading .../mood_catalog_test.dart (failed)`).

## Fix
- Renamed the local helper to `isEligible`; the variable stays `eligible`.
  Behaviour is identical — no Mood feature was removed or changed.
- `test/mood_catalog_test.dart` now imports `package:sursathi/services/mood_catalog.dart`
  only and uses the literal `'bollywood'` code instead of pulling the whole UI
  tree in for one string.

Not run here (no Flutter SDK in sandbox): `flutter analyze`, `flutter test`.
