# SurSathi v109 — Adaptive Radio learning

## Purpose

This release makes the Radio recommendation loop learn from real listening behaviour instead of depending mostly on likes, mood and search rank.

## Changes

- Persist `listenSeconds`, `completionRatio`, and `replayCount` in Radio history.
- Use the exact manual-skip position to derive early/mid/late preference signals for tags and artists.
- Treat manual Next inside the final 10% as a completed listen so an almost-finished song is not punished as a skip.
- Treat Previous/replay as an explicit positive signal without disabling the 150-day forward-repeat rule.
- Apply short-term artist fatigue so one singer does not dominate consecutive Radio picks.
- Apply mild tag/mood diversity while building the next-10 look-ahead.
- Keep a small exploration boost for artists/areas with little history.
- Preserve old v108 history: legacy completed records are decoded as completed rather than losing their positive signal.

## Root cause addressed

v108 already stored skip position, but recommendation learning was still coarse. It did not persist an explicit completion ratio or replay count and had no short-term artist-fatigue layer. A 5-second rejection and an almost-complete listen therefore did not provide a sufficiently precise feedback loop, and repeated artists could dominate a look-ahead.

## Implementation note

This is an original SurSathi recommendation layer inspired by publicly described behaviour-based music recommendation concepts. Resso's proprietary internal formula/weights are not known and are not reproduced here.

## Attribution

Implementation and documentation prepared by ChatGPT on 2026-09-19 at the user's request. The implementation is original to SurSathi; the reason for the change was to make the Radio behaviour actually learn from listening rather than merely look like an adaptive UI.
