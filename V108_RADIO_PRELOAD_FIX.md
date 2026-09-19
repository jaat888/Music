# V108 — Radio Candidate Generation + Preload Fix

Date: 2026-09-19

## User-reported problem

Radio me kabhi-kabhi agla song generate nahi hota, ya Up Next me aa jaane ke baad bhi preload ready nahi hota.

## Root causes found

- Initial Radio candidate set finite tha; long session me hard 150-day history + failed-session + duplicate filters ke baad pool zero/low ho sakta tha.
- Look-ahead fill ek hi existing candidate pass par dependent tha.
- URL prefetch window sirf 1 effective Radio item tak limited thi.
- Prefetch serial tha aur failure ke baad retry nahi tha.
- Dart `Future.timeout()` source resolver ko cancel nahi karta; isliye timeout ko hard cancellation samajhna galat tha.
- Warm URL ko permanent cache maan liya ja sakta tha even though media URL stale ho sakta hai.
- Candidate generation, URL warm-up aur actual AudioPlayer buffering teen separate stages the.

## V108 changes

- Radio candidate fetch now keeps the fast YT Music first pass and adds InnerTube continuation top-up when the candidate pool is too small.
- `_fillUpcoming()` refreshes candidates when the look-ahead cannot be filled.
- Radio warm-up window is now 3 songs.
- Warm URLs use a deduplicated serialized queue.
- Each warm-up gets up to 2 resolve attempts.
- Warm URL cache expires after 5 minutes.
- Stale queued prefetch work outside the current three-song window is pruned.
- Radio current-track full-file cache is deferred by 6 seconds so weak-network sessions prioritize next-song URL warm-up first.
- Logging now distinguishes warm-up success, timeout and failure.

## Important design decision

V108 does not call `setUrl()` on the shared active `AudioPlayer` for a future song, because that would replace the currently playing source. Therefore this pass guarantees **URL warm-up**, not a second hidden decoded audio buffer. `just_audio` supports playlist/lazy preparation, but adopting that model would be a larger playback architecture refactor.

## Verification

Source/static validation only. Flutter/Dart SDK and a real Android playback environment were not available in this execution environment.

## Attribution

This V108 change set was produced by ChatGPT (OpenAI) at the user's request.
