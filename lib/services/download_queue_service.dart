// lib/services/download_queue_service.dart
//
// v37 se v40 tak ye queue "serial" thi (ek waqt me sirf 1 gaana download
// hota tha) — jaan-boojh kar taaki pehle wale parallel-download crash/lag
// bug se bachaa ja sake.
//
// 2026-09-17 (v42) — user report: (a) poori playlist (jaise 98 gaane)
// download karte waqt app lag karti hai, (b) download speed baaki apps
// jaisi fast nahi lagti, (c) "Pause All" jaisa option chahiye taaki
// download beech me rok saken.
//
// Fix:
//   1. SPEED — ab ek waqt me sirf 1 nahi, `maxConcurrent` (=3) gaane
//      parallel download hote hain (chhota, safe worker-pool — poori
//      playlist ek saath nahi, taaki wahi purana crash/lag pattern wapas
//      na aaye, lekin 3x tak zyada throughput milta hai).
//   2. LAG (bulk playlist add) — pehle poori playlist ke liye ek loop mein
//      `enqueue()` baar-baar call hota tha (har baar apna `notifyListeners()`
//      — 98 gaano ke liye 98 back-to-back UI rebuild ek hi frame ke andar,
//      isi se "lag" hota tha jab poori playlist ek saath download pe lagti
//      thi). Naya `enqueueAll(List<Song>)` sab songs ek saath list mein daal
//      ke sirf EK baar notify karta hai.
//   3. PAUSE ALL — `pauseAll()`/`resumeAll()`. NOTE (honest limitation):
//      jo gaane ABHI download ho rahe hain (in-flight HTTP), unhe turant
//      cancel nahi karta (उसके liye YoutubeService.download() mein
//      CancelToken plumbing chahiye, jo abhi nahi hai) — pause karne par wo
//      chal rahe downloads apni jagah poora ho jaate hain, bas QUEUE mein
//      pade agle gaano ka start rok deta hai. Practically, chhote
//      maxConcurrent (3) ki wajah se ye kaafi fast rukta hai.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/song.dart';
import 'notification_service.dart';
import 'youtube_service.dart';

class DownloadQueueService extends ChangeNotifier {
  DownloadQueueService._internal();
  static final DownloadQueueService instance = DownloadQueueService._internal();

  static const int maxConcurrent = 3;

  final List<Song> _queue = [];
  // Abhi active (in-flight) downloads — songId -> Song
  final Map<String, Song> _active = {};
  final Map<String, double> _progress = {};
  int _runningWorkers = 0;
  bool _paused = false;

  List<Song> get queue => List.unmodifiable(_queue);
  List<Song> get activeSongs => List.unmodifiable(_active.values);
  double progressOf(String id) => _progress[id] ?? 0;
  bool get isPaused => _paused;
  bool get isIdle => _active.isEmpty && _queue.isEmpty;

  // BACKWARD-COMPAT getters (purani UI single-song model use karti thi) —
  // "current" = pehla active download (agar koi ho).
  Song? get currentSong => _active.isEmpty ? null : _active.values.first;
  double get currentProgress =>
      currentSong == null ? 0 : (_progress[currentSong!.id] ?? 0);

  bool isQueued(String id) => _queue.any((s) => s.id == id);
  bool isDownloading(String id) => _active.containsKey(id);
  bool isActive(String id) => isQueued(id) || isDownloading(id);

  final List<void Function(Song song, bool success)> _finishListeners = [];

  void addFinishListener(void Function(Song song, bool success) listener) {
    _finishListeners.add(listener);
  }

  void removeFinishListener(void Function(Song song, bool success) listener) {
    _finishListeners.remove(listener);
  }

  void _notifyFinished(Song song, bool success) {
    for (final l in List.of(_finishListeners)) {
      try {
        l(song, success);
      } catch (_) {}
    }
  }

  void enqueue(Song song) {
    if (isActive(song.id)) return;
    _queue.add(song);
    notifyListeners();
    _spawnWorkersIfNeeded();
  }

  // NEW (v42): poori playlist/album ek saath download-queue mein daalne ke
  // liye — sirf EK notifyListeners() (bulk-add lag fix).
  void enqueueAll(Iterable<Song> songs) {
    var added = false;
    for (final song in songs) {
      if (isActive(song.id)) continue;
      _queue.add(song);
      added = true;
    }
    if (added) {
      notifyListeners();
      _spawnWorkersIfNeeded();
    }
  }

  void pauseAll() {
    if (_paused) return;
    _paused = true;
    notifyListeners();
  }

  void resumeAll() {
    if (!_paused) return;
    _paused = false;
    notifyListeners();
    _spawnWorkersIfNeeded();
  }

  // Sirf abhi-tak-shuru-na-hue (queued) gaane hatata hai — jo abhi download
  // ho rahe hain unhe force-stop nahi karta (dekho file ke top ka
  // "PAUSE ALL" honest-limitation note).
  void clearQueue() {
    if (_queue.isEmpty) return;
    _queue.clear();
    notifyListeners();
  }

  void _spawnWorkersIfNeeded() {
    if (_paused) return;
    while (_runningWorkers < maxConcurrent && _queue.isNotEmpty) {
      _runningWorkers++;
      unawaited(_workerLoop());
    }
  }

  Future<void> _workerLoop() async {
    try {
      while (!_paused && _queue.isNotEmpty) {
        final song = _queue.removeAt(0);
        _active[song.id] = song;
        _progress[song.id] = 0;
        notifyListeners();
        unawaited(_pushNotification());

        var success = false;
        var lastNotifiedPct = -1;
        try {
          final path = await YoutubeService.instance.download(
            song.id,
            song.title,
            author: song.artist,
            onProgress: (received, total) {
              if (total <= 0) return;
              final p = received / total;
              _progress[song.id] = p;
              final pct = (p * 100).round();
              if (pct == lastNotifiedPct) return;
              lastNotifiedPct = pct;
              // BUG FIX (v40, ab bhi lagu): sirf % badalne par hi notify —
              // har chunk pe nahi, warna 3 parallel downloads ke saath UI
              // rebuild aur bhi zyada baar fire hoke ulta lag kar deta.
              notifyListeners();
              if (pct % 10 == 0) unawaited(_pushNotification());
            },
          );
          success = path != null;
        } catch (e) {
          success = false;
        }

        _notifyFinished(song, success);
        _active.remove(song.id);
        _progress.remove(song.id);
        notifyListeners();
      }
    } finally {
      _runningWorkers--;
      if (_runningWorkers == 0 && _active.isEmpty) {
        await NotificationService.instance.cancelDownloadProgress();
      } else if (!_paused) {
        // Is worker ka kaam khatam ho gaya lekin queue mein abhi bhi kuch
        // ho sakta hai (dusre worker abhi busy the jab ye nikla) — dobara
        // check karo taaki koi gaana queue mein "atka" na reh jaaye.
        _spawnWorkersIfNeeded();
      }
    }
  }

  Future<void> _pushNotification() async {
    try {
      final active = _active.values.toList();
      if (active.isEmpty) return;
      final first = active.first;
      await NotificationService.instance.showDownloadProgress(
        songTitle: active.length > 1
            ? '${first.title} +${active.length - 1} aur'
            : first.title,
        progressPercent: ((_progress[first.id] ?? 0) * 100).round(),
        queuedCount: _queue.length,
      );
    } catch (_) {
      // Notification fail ho to bhi download ruknа nahi chahiye.
    }
  }
}
