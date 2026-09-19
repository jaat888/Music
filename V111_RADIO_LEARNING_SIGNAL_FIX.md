# V111 — Radio recent-artist + skip-signal correctness fix

Prepared by ChatGPT on 2026-09-19.

## Bug 1: persisted `recentArtistCounts()` was not wired

### Before
`radio_history_store.dart` already persisted a 45-minute recent-artist count, but `radio_player_screen.dart` built artist fatigue only from `_playedStack`.

### After
The ranking helper starts from persisted 45-minute counts (excluding the current session song IDs) and merges the current in-memory session tail/current candidate so short-term artist fatigue survives session recreation without waiting for an async history write.

## Bug 2: skip timing was double-counted

### Before
Skipped entries contributed early/mid/late timing through `_entrySignal()`, while the engine also added dedicated `tagSkipTimingAffinity()` and `artistSkipTimingAffinity()`.

### After
Generic `tagAffinity()` and `artistAffinity()` ignore skipped entries. Dedicated skip-timing maps are the single skip-timing source for tag/artist ranking. Completed listens and replays remain in generic affinity.

## Tests

- persisted 45-minute artist count is returned;
- skipped entries do not populate generic tag/artist affinity while dedicated skip timing still records the event.

## Version
`1.0.0+557` → `1.0.0+558`
