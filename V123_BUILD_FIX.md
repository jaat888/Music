# V123 — Playlist/Miniplayer build fix

- Fixed `background_service.dart`: `_drainPrefetchQueue()` returns `void`, so its fire-and-forget call is a plain `_drainPrefetchQueue();` instead of `unawaited(...)`.
- Fixed `mini_player.dart`: replaced `context.watch<QueueService>()` with explicit `Provider.of<QueueService>(context, listen: true)` to avoid the BuildContext extension resolution error reported by the CI build.
- No playback, Radio, playlist, download, or matching behavior changed in this patch.
