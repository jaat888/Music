// lib/services/download_queue_service.dart
//
// NEW (v37 — bug report: "playlist/download ka option nahi ata aur na
// pata chalta kaunsa gaana queue mein hai; notification mein bhi kaunsa
// download ho raha hai kaunsa queue mein hai kabhi nahi dikhta").
//
// Root cause: pehle har screen (home/artist/album/liked/playlist/mood/
// smart) apna khud ka `_download(Song)` method rakhta tha jo seedha
// `YoutubeService.instance.download()` call karta — koi shared state
// nahi thi, isliye:
//   1) Do jagah se same/alag gaane ek saath download karo to koi "queue"
//      concept hi nahi tha — sab parallel chalte, koi progress/order
//      track nahi hota.
//   2) Kahin bhi "ye gaana abhi download ho raha hai" ya "ye queue mein
//      hai" dikhane ka koi tarika nahi tha (na UI mein, na notification
//      mein) — sirf ek generic "download ho gaya" / "fail ho gaya"
//      SnackBar end mein aata tha.
//
// Fix: ek single, app-wide serial queue (ek waqt me sirf ek download
// chalta hai — taaki bahut saare parallel network calls se dobara wahi
// "app crash/lag" wala pattern na ho jo is app mein playback ke liye
// pehle fix kiya gaya tha). ChangeNotifier hai taaki koi bhi screen
// `isQueued`/`isDownloading` se turant UI (spinner/queued-badge) dikha
// sake, aur ek persistent notification (NotificationService) progress %
// aur "N aur queue mein" hamesha dikhati rehti hai jab tak queue khaali
// na ho jaaye.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'notification_service.dart';
import 'youtube_service.dart';

class DownloadQueueService extends ChangeNotifier {
  DownloadQueueService._internal();
  static final DownloadQueueService instance = DownloadQueueService._internal();

  final List<Song> _queue = [];
  Song? _currentSong;
  double _currentProgress = 0; // 0.0 - 1.0, sirf currentSong ke liye
  bool _processing = false;

  List<Song> get queue => List.unmodifiable(_queue);
  Song? get currentSong => _currentSong;
  double get currentProgress => _currentProgress;
  bool get isIdle => _currentSong == null && _queue.isEmpty;

  bool isQueued(String id) => _queue.any((s) => s.id == id);
  bool isDownloading(String id) => _currentSong?.id == id;
  bool isActive(String id) => isQueued(id) || isDownloading(id);

  // Screens (Downloads screen, SongCard wagaira) isse subscribe kar sakte
  // hain taaki ek download poora hone pe apni list turant refresh kar
  // sakein (nayi entry DownloadDB mein already `YoutubeService.download()`
  // khud add kar deta hai — isse sirf UI-refresh trigger karne ke liye).
  //
  // BUG FIX (v37): pehle ye ek single nullable field tha — jis screen ne
  // sabse aakhri baar set kiya wahi "jeetta" tha, aur baaki sab (jaise
  // main.dart ka global "download ho gaya" SnackBar) permanently overwrite
  // ho jaate the, chahe wo screen ab visible bhi na ho. Ab ek list hai —
  // multiple listeners (global + per-screen) ek saath, bina ek-doosre ko
  // hataye, kaam kar sakte hain. Screens `addListener`/`removeListener`
  // (standard ChangeNotifier tarah nahi — ye custom hai) use karke apna
  // callback register/unregister karein (dispose() mein hatana zaroori hai).
  final List<void Function(Song song, bool success)> _finishListeners = [];

  void addFinishListener(void Function(Song song, bool success) listener) {
    _finishListeners.add(listener);
  }

  void removeFinishListener(void Function(Song song, bool success) listener) {
    _finishListeners.remove(listener);
  }

  void _notifyFinished(Song song, bool success) {
    // List ka copy pe iterate karo — agar koi listener khud ke andar
    // add/removeFinishListener call kare to concurrent-modification error
    // na aaye.
    for (final l in List.of(_finishListeners)) {
      try {
        l(song, success);
      } catch (_) {
        // Ek listener ka crash baaki listeners ko block na kare.
      }
    }
  }

  // Duplicate check: agar already download/cache mein hai to
  // `YoutubeService.download()` khud turant (existingPath) return kar
  // dega — isliye yahan dobara DB check karne ki zaroorat nahi, bas
  // in-flight duplicate (already queued/downloading) rokna kaafi hai.
  void enqueue(Song song) {
    if (isActive(song.id)) return;
    _queue.add(song);
    notifyListeners();
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final song = _queue.removeAt(0);
        _currentSong = song;
        _currentProgress = 0;
        notifyListeners();
        await _pushNotification(song);

        var success = false;
        try {
          final path = await YoutubeService.instance.download(
            song.id,
            song.title,
            author: song.artist,
            onProgress: (received, total) {
              if (total <= 0) return;
              _currentProgress = received / total;
              notifyListeners();
              // Notification bahut baar update na ho (spam) — sirf har
              // ~5% pe refresh karo.
              final pct = (_currentProgress * 100).round();
              if (pct % 5 == 0) {
                unawaited(_pushNotification(song));
              }
            },
          );
          success = path != null;
        } catch (e) {
          success = false;
        }

        _notifyFinished(song, success);
        _currentSong = null;
        _currentProgress = 0;
        notifyListeners();
      }
    } finally {
      _processing = false;
      await NotificationService.instance.cancelDownloadProgress();
    }
  }

  Future<void> _pushNotification(Song song) async {
    try {
      await NotificationService.instance.showDownloadProgress(
        songTitle: song.title,
        progressPercent: (_currentProgress * 100).round(),
        queuedCount: _queue.length,
      );
    } catch (_) {
      // Notification fail ho to bhi download ruknа nahi chahiye.
    }
  }
}
