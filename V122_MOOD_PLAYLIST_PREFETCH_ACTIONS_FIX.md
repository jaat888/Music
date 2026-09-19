# V122 — Mood/Playlist speed + MiniPlayer + actions

Implemented the requested playlist UX/performance changes:

- Curated JioSaavn/iTunes playlist matching now searches YouTube in 10-track parallel waves instead of one track at a time.
- Spotify playlist import now matches tracks in the same 10-at-a-time pattern.
- Playback warm-up resolves up to 20 upcoming playlist songs with 10 concurrent workers; this caches short-lived stream URLs only and does not download audio files.
- Live YouTube Music playlists start the first-20-song warm-up as soon as the playlist tracks arrive.
- MiniPlayer visibility now has a QueueService fallback, so the bar remains visible during the mediaItem publication/resolve hand-off.
- Live, curated and local playlist screens expose Add to Playlist and Download actions on individual songs.
- Live playlist keeps playlist-wide Add/Save and Download controls.
- Bulk local playlist saving uses one SQLite batch commit instead of one DB commit per song.
