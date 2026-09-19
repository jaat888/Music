# V110 — Radio Preload Caller Consistency Fix

## Problem found
A source review found two `prefetchRadioSongs()` calls in `radio_player_screen.dart` using different windows:
- `_playCandidate()` used `_upcoming.take(2)`
- `_preloadArtworkAndMetadata()` used `_upcoming.take(3)`

The V108/V109 documentation described a 3-song warm window, but the older direct caller remained. That created duplicate/competing prefetch passes and made the effective behavior timing-dependent.

## Fix
The direct prefetch from `_playCandidate()` was removed. `_fillUpcoming()` now owns look-ahead filling, and after it completes the existing `_preloadArtworkAndMetadata()` path performs the single authoritative Radio warm-up.

## Result
There is now one Radio preload owner and one configured warm window (3 songs). The old `take(2)` caller is gone.

## Why the bug happened
V108 introduced the 3-song warm-up in the newer preload path but did not remove an older 2-song prefetch call. V109 inherited the leftover.

## Version
`1.0.0+557`

Prepared by ChatGPT during source audit/bug-fix pass.
