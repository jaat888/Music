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
//   1. SPEED — ab ek waqt me sirf 1 nahi, `maxConcurrent` (=5, dekho neeche
//      — cache-reuse fix ke baad safe) gaane parallel download hote hain
//      (chhota, safe worker-pool — poori playlist ek saath nahi, taaki
//      wahi purana crash/lag pattern wapas na aaye, lekin zyada throughput
//      milta hai).
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

  // BUMPED (2026-09-17, user request): 3 → 5. Cache-reuse fix (dekho
  // youtube_service.dart download()) ne per-song network load kaafi kam
  // kar diya hai (jo gaana pehle se cached hai uske liye ye ab sirf local
  // disk copy hai, koi extra network hit nahi) — isliye 5 parallel
  // network-download bhi ab safe hain.
  static const int maxConcurrent = 5;

  final List<Song> _queue = [];
  // Abhi active (in-flight) downloads — songId -> Song
  final Map<String, Song> _active = {};
  final Map<String, double> _progress = {};
  // NEW (2026-09-17 — "1 minute lag jaata hai, atka hua lagta hai"): resolve
  // phase ka status text (dekho youtube_service.dart download() ka naya
  // onStatus param) — progress ke 0% pe atke rehne ke dauraan bhi UI ko
  // pata rehta hai "abhi kya ho raha hai".
  final Map<String, String> _statusText = {};
  int _runningWorkers = 0;
  bool _paused = false;

  // NEW (2026-09-17 — "animation mein lag hota hai"): 5 parallel workers
  // ek saath apna apna notifyListeners() call karte the (progress % badalne
  // par) — ek saath kai listeners aane se UI rebuild bahut baar-baar hoti
  // thi, jo chhote/kam-RAM devices pe stutter jaisa lagta tha. Ab
  // notifyListeners() zyada se zyada har ~120ms me ek baar hi fire hota hai
  // (progress ke liye) — start/finish/status jaise "important" events ab
  // bhi turant fire hote hain, sirf tez-tez aane wale % updates throttle
  // hote hain.
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastProgressNotify = now;
    notifyListeners();
  }

  List<Song> get queue => List.unmodifiable(_queue);
  List<Song> get activeSongs => List.unmodifiable(_active.values);
  double progressOf(String id) => _progress[id] ?? 0;
  String? statusOf(String id) => _statusText[id];
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
        _statusText.remove(song.id);
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
              // BUG FIX (v40, ab bhi lagu; v48 — time-throttle bhi add):
              // sirf % badalne par hi notify, aur ab max har ~120ms — warna
              // parallel downloads ke saath UI rebuild bahut zyada baar
              // fire hoke ulta lag/stutter kar deta.
              _notifyThrottled();
              if (pct % 10 == 0) unawaited(_pushNotification());
            },
            // NEW (2026-09-17): resolve-phase status text — progress abhi
            // 0% hi hai to bhi UI ko pata chalta rehta hai kya chal raha
            // hai ("atka hua" jaisa nahi lagta).
            onStatus: (status) {
              _statusText[song.id] = status;
              _notifyThrottled();
            },
          );
          success = path != null;
        } catch (e) {
          success = false;
        }

        _notifyFinished(song, success);
        _active.remove(song.id);
        _progress.remove(song.id);
        _statusText.remove(song.id);
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
