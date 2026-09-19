// lib/services/queue_service.dart
// Sirf queue ka STATE rakhta hai — actual playback control Batch 5 ke
// audio handler se hoga, ye service usko sirf "kya bajna hai" batata hai.

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/song.dart';

enum SurRepeatMode { off, all, one }

class QueueService extends ChangeNotifier {
  QueueService._internal() : _random = Random();
  static final QueueService instance = QueueService._internal();

  // Unit tests ke liye alag (non-singleton) instance + seedable Random.
  @visibleForTesting
  QueueService.forTesting({Random? random}) : _random = random ?? Random();

  final List<Song> _queue = [];
  int _currentIndex = -1;
  bool _shuffle = false;
  SurRepeatMode _repeat = SurRepeatMode.off;

  // ---------------- Radio mode (unlimited auto-refill) ----------------
  //
  // NEW (2026-09-16, v19): jab radio mode on hai, queue khatam hone se
  // pehle hi (last 3 gaane reh jaane par) khud-ba-khud `_radioSupplier`
  // se agla batch maangta hai aur queue me jod deta hai — isse "radio
  // unlimited chalta rahe" wala feel milta hai bina QueueService ko
  // YoutubeService ke baare me kuch jaane (loose coupling — supplier
  // caller set karta hai).
  bool _radioMode = false;
  Future<List<Song>> Function()? _radioSupplier;
  bool _radioFetching = false;
  int _radioGeneration = 0;

  bool get radioMode => _radioMode;

  void enableRadioMode(Future<List<Song>> Function() supplier) {
    _radioGeneration++;
    _radioMode = true;
    _radioSupplier = supplier;
    _radioFetching = false;
    notifyListeners(); // FIX: UI (radio icon) ko turant reflect karne ke liye
  }

  void disableRadioMode() {
    _radioGeneration++;
    _radioMode = false;
    _radioSupplier = null;
    _radioFetching = false;
    notifyListeners();
  }

  void _maybeRefillRadio() {
    if (!_radioMode || _radioSupplier == null || _radioFetching) return;
    if (_queue.isEmpty) return;
    // Aakhri 3 gaano ke andar aa gaye to abhi se agla batch mangwa lo,
    // taaki gaana khatam hote hote naya batch pehle se ready ho.
    // v106: "aakhri 3 gaane" ab PLAY ORDER ke hisaab se gine jaate hain
    // (shuffle on ho to `_currentIndex` linear position se kuch matlab nahi).
    if (_remainingAfterCurrent() > 2) return;

    final generation = _radioGeneration;
    final supplier = _radioSupplier;
    if (supplier == null) return;
    _radioFetching = true;
    supplier().then((more) {
      // Supplier may have completed after Radio mode was replaced/disabled.
      // Never let that stale batch leak into a new queue/session.
      if (generation != _radioGeneration || !_radioMode || !identical(_radioSupplier, supplier)) {
        return;
      }
      _radioFetching = false;
      if (more.isNotEmpty) {
        final existingIds = _queue.map((song) => song.id).toSet();
        final fresh = more.where((song) => existingIds.add(song.id)).toList();
        if (fresh.isEmpty) return;
        final oldLength = _queue.length;
        _queue.addAll(fresh);
        _syncOrderAfterAppend(oldLength);
        notifyListeners();
      }
    }).catchError((_) {
      if (generation == _radioGeneration && identical(_radioSupplier, supplier)) {
        _radioFetching = false;
      }
    }).whenComplete(() {
      if (generation == _radioGeneration && identical(_radioSupplier, supplier)) {
        _radioFetching = false;
      }
    });
  }

  // v106 — SHUFFLE ab asli mein kaam karta hai.
  //
  // `_shuffleOrder` = queue indices ki ek permutation jo shuffle ON hone par
  // PLAY ORDER hai (`_queue` khud kabhi shuffle/reorder nahi hoti shuffle ki
  // wajah se, isliye shuffle OFF karte hi original order wapas mil jaata
  // hai). Pehle ye list bani to thi lekin next()/previous()/upcoming kahin
  // use hi nahi hoti thi — `setShuffle(true)` ka koi asar nahi tha (screens
  // pehle se `list.shuffle()` karke queue bhejti thi, wahi "shuffle" lagta
  // tha).
  //
  // Invariants:
  //  * `_shuffleOrder` mein har queue index EXACTLY ek baar hai.
  //  * current song hamesha `_shuffleOrder` mein hai; uski position =
  //    `_orderPos(_currentIndex)`. Us se pehle wale "played" hain (previous
  //    inhi pe chalta hai), baad wale "Up Next".
  //  * Har mutator (add/removeAt/reorder/jumpTo...) order ko incrementally
  //    maintain karta hai — Up Next baar-baar random reshuffle nahi hota.
  //    `_ensureOrder()` sirf safety-net hai (length mismatch pe full rebuild).
  List<int> _shuffleOrder = [];
  final Random _random;

  @visibleForTesting
  List<int> get shuffleOrderForTesting => List.unmodifiable(_shuffleOrder);

  List<Song> get queue => List.unmodifiable(_queue);
  bool get shuffle => _shuffle;
  SurRepeatMode get repeat => _repeat;

  // Queue screen ko "Up Next" ke local index ko full queue index me
  // convert karne ke liye chahiye (removeAt/reorder dono full-queue index lete hain)
  int get currentIndex => _currentIndex;

  Song? get currentSong =>
      (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : null;

  // Current ke baad ke upcoming songs, PLAY ORDER me (queue screen, prefetch).
  // Shuffle off: physical queue order. Shuffle on: `_shuffleOrder` order.
  List<Song> get upcoming =>
      upcomingIndices.map((i) => _queue[i]).toList(growable: false);

  // `upcoming` ke har item ka FULL-queue index (same order/length) — queue
  // screen ko removeAt/jumpTo ke liye chahiye (shuffle mein `currentIndex + 1
  // + i` galat hota).
  List<int> get upcomingIndices {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return const <int>[];
    if (_shuffle) {
      _ensureOrder();
      final pos = _orderPos(_currentIndex);
      if (pos < 0) return const <int>[];
      return List<int>.unmodifiable(_shuffleOrder.sublist(pos + 1));
    }
    if (_currentIndex >= _queue.length - 1) return const <int>[];
    return List<int>.generate(
      _queue.length - _currentIndex - 1,
      (i) => _currentIndex + 1 + i,
    );
  }

  // Play order mein current ke baad kitne gaane bache hain.
  int _remainingAfterCurrent() {
    if (_currentIndex < 0 || _queue.isEmpty) return 0;
    if (_shuffle) {
      _ensureOrder();
      final pos = _orderPos(_currentIndex);
      return pos < 0 ? 0 : _shuffleOrder.length - 1 - pos;
    }
    return _queue.length - 1 - _currentIndex;
  }

  // Current song play order ka aakhri gaana hai? (background_service ka
  // "last song + repeat off => stop" check ab `currentIndex == length - 1`
  // nahi, ye use karta hai — shuffle mein woh galat hota.)
  bool get isLastInPlayOrder =>
      _currentIndex >= 0 && _remainingAfterCurrent() == 0;

  // ---------------- Queue modify karna ----------------

  void add(Song song) {
    final oldLength = _queue.length;
    _queue.add(song);
    if (_currentIndex == -1) _currentIndex = 0;
    _syncOrderAfterAppend(oldLength);
    notifyListeners();
  }

  void addAll(List<Song> songs) {
    final oldLength = _queue.length;
    _queue.addAll(songs);
    if (_currentIndex == -1 && _queue.isNotEmpty) _currentIndex = 0;
    _syncOrderAfterAppend(oldLength);
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    _ensureOrder();
    final removedPos = _orderPos(index);
    final wasCurrent = index == _currentIndex;

    _queue.removeAt(index);
    // Order se bhi hatao, aur jo indices hate hue index se bade the unhe
    // ek se neeche shift karo (baaki order bilkul waisa hi rehta hai).
    if (removedPos >= 0) _shuffleOrder.removeAt(removedPos);
    for (var k = 0; k < _shuffleOrder.length; k++) {
      if (_shuffleOrder[k] > index) _shuffleOrder[k]--;
    }

    if (index < _currentIndex) {
      _currentIndex--;
    } else if (wasCurrent) {
      // Current hi hata diya — agla song current ban jayega. Shuffle ON mein
      // "agla" = play order mein agla; warna physical queue mein wahi index.
      if (_shuffle && _shuffleOrder.isNotEmpty && removedPos >= 0) {
        final p = removedPos > _shuffleOrder.length - 1
            ? _shuffleOrder.length - 1
            : removedPos;
        _currentIndex = _shuffleOrder[p];
      } else if (_currentIndex >= _queue.length) {
        _currentIndex = _queue.length - 1;
      }
    }
    if (_queue.isEmpty) _currentIndex = -1;
    notifyListeners();
  }

  void clear() {
    _queue.clear();
    _currentIndex = -1;
    _shuffleOrder.clear();
    disableRadioMode();
    notifyListeners();
  }

  // Poori queue replace karke ek naye set se play shuru karo
  void setQueue(List<Song> songs, {int startIndex = 0}) {
    _queue
      ..clear()
      ..addAll(songs);
    _currentIndex = songs.isEmpty ? -1 : startIndex.clamp(0, songs.length - 1);
    // Naya (non-radio) source se poori queue replace ho rahi hai — purana
    // radio mode yahan carry-forward nahi hona chahiye.
    disableRadioMode();
    _rebuildShuffleOrder();
    notifyListeners();
  }

  // ---------------- Navigation ----------------

  void next() {
    if (_queue.isEmpty) return;

    if (_repeat == SurRepeatMode.one) {
      notifyListeners(); // same song replay — player isi index pe seek(0) karega
      return;
    }

    if (_shuffle) {
      // v106: play order (`_shuffleOrder`) mein agla gaana.
      _ensureOrder();
      final pos = _orderPos(_currentIndex);
      if (pos >= 0 && pos + 1 < _shuffleOrder.length) {
        _currentIndex = _shuffleOrder[pos + 1];
      } else if (_repeat == SurRepeatMode.all) {
        _startNewShuffleCycle();
      }
      // repeat off aur order khatam — currentIndex wahi rehta hai, player ruk jayega
    } else {
      final nextIndex = _currentIndex + 1;
      if (nextIndex < _queue.length) {
        _currentIndex = nextIndex;
      } else if (_repeat == SurRepeatMode.all) {
        _currentIndex = 0;
      }
      // repeat off aur queue khatam — currentIndex wahi rehta hai, player ruk jayega
    }
    _maybeRefillRadio();
    notifyListeners();
  }

  void previous() {
    if (_queue.isEmpty) return;

    if (_shuffle) {
      // v106: play order mein pichla gaana (jo pehle bajaya gaya tha).
      _ensureOrder();
      final pos = _orderPos(_currentIndex);
      if (pos > 0) {
        _currentIndex = _shuffleOrder[pos - 1];
      } else if (_repeat == SurRepeatMode.all && _shuffleOrder.isNotEmpty) {
        _currentIndex = _shuffleOrder.last;
      }
    } else {
      final prevIndex = _currentIndex - 1;
      if (prevIndex >= 0) {
        _currentIndex = prevIndex;
      } else if (_repeat == SurRepeatMode.all) {
        _currentIndex = _queue.length - 1;
      }
    }
    notifyListeners();
  }

  void jumpTo(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (_shuffle && index != _currentIndex) {
      // Shuffle ON mein chuna hua gaana play order mein current ke TURANT
      // baad la do — taaki previous() us gaane par jaaye jo abhi baj raha
      // tha (beech ke skipped gaane "played" na ban jaayein).
      _ensureOrder();
      final cur = _orderPos(_currentIndex);
      final tgt = _orderPos(index);
      if (cur >= 0 && tgt >= 0 && tgt != cur + 1) {
        _shuffleOrder.removeAt(tgt);
        _shuffleOrder.insert(tgt < cur ? cur : cur + 1, index);
      }
    }
    _currentIndex = index;
    notifyListeners();
  }

  // Drag-and-drop reorder (Queue screen) — oldIndex/newIndex full _queue ke
  // against hain. Flutter ke ReorderableListView convention follow karta hai:
  // agar oldIndex < newIndex, to newIndex ko ek se adjust karna padta hai
  // kyunki purana item pehle hi list se nikal chuka hota hai.
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= _queue.length) return;
    if (oldIndex == newIndex) return;

    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, item);

    // currentIndex ko bhi naye position ke hisaab se shift karo taaki
    // "abhi kya baj raha hai" wahi rahe
    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }

    // Physical move ke saath order ke entries (queue indices) bhi map karo —
    // play order (positions) ko touch kiye bina.
    for (var k = 0; k < _shuffleOrder.length; k++) {
      final v = _shuffleOrder[k];
      if (v == oldIndex) {
        _shuffleOrder[k] = newIndex;
      } else if (oldIndex < newIndex && v > oldIndex && v <= newIndex) {
        _shuffleOrder[k] = v - 1;
      } else if (oldIndex > newIndex && v >= newIndex && v < oldIndex) {
        _shuffleOrder[k] = v + 1;
      }
    }
    notifyListeners();
  }

  // Queue screen ka "Up Next" drag-reorder — indices `upcoming` list ke LOCAL
  // indices hain (ReorderableListView convention). Shuffle OFF: physical
  // queue reorder. Shuffle ON: sirf play order badalta hai.
  void reorderUpcoming(int oldLocal, int newLocal) {
    if (!_shuffle) {
      final base = _currentIndex + 1;
      reorder(base + oldLocal, base + newLocal);
      return;
    }
    _ensureOrder();
    final pos = _orderPos(_currentIndex);
    if (pos < 0) return;
    final base = pos + 1;
    final count = _shuffleOrder.length - base;
    if (oldLocal < 0 || oldLocal >= count) return;
    if (oldLocal < newLocal) newLocal -= 1;
    if (newLocal < 0 || newLocal >= count || oldLocal == newLocal) return;
    final moved = _shuffleOrder.removeAt(base + oldLocal);
    _shuffleOrder.insert(base + newLocal, moved);
    notifyListeners();
  }

  // ---------------- Shuffle / Repeat ----------------

  void setShuffle(bool value) {
    if (_shuffle == value) return;
    _shuffle = value;
    // ON: naya random play order, current song sabse pehle (jump nahi).
    // OFF: `_currentIndex` physical position hai hi — wahin se linear chalega.
    if (value) _rebuildShuffleOrder();
    notifyListeners();
  }

  void setRepeat(SurRepeatMode mode) {
    _repeat = mode;
    notifyListeners();
  }

  // ---------------- Shuffle play-order helpers ----------------

  int _orderPos(int queueIndex) => _shuffleOrder.indexOf(queueIndex);

  // Safety-net: order queue se out-of-sync ho jaye to fresh rebuild.
  void _ensureOrder() {
    if (_shuffleOrder.length != _queue.length) _rebuildShuffleOrder();
  }

  // Fresh random order; current song sabse pehle (agar valid ho).
  void _rebuildShuffleOrder() {
    final order = List<int>.generate(_queue.length, (i) => i)..shuffle(_random);
    if (_currentIndex >= 0 && _currentIndex < order.length) {
      order.remove(_currentIndex);
      order.insert(0, _currentIndex);
    }
    _shuffleOrder = order;
  }

  // Queue ke END mein gaane jode gaye (add/addAll/radio refill): naye indices
  // aapas mein shuffle hoke order ke end mein — Up Next ka purana order
  // bilkul nahi chhedta.
  void _syncOrderAfterAppend(int oldLength) {
    if (oldLength == 0 || _shuffleOrder.length != oldLength) {
      _rebuildShuffleOrder();
      return;
    }
    final added = List<int>.generate(
      _queue.length - oldLength,
      (i) => oldLength + i,
    )..shuffle(_random);
    _shuffleOrder.addAll(added);
  }

  // Repeat-all + shuffle: order khatam hone par naya cycle. Naya cycle us
  // gaane se shuru nahi hota jo abhi khatam hua (queue > 1 gaane ki ho to).
  void _startNewShuffleCycle() {
    final finished = _currentIndex;
    final order = List<int>.generate(_queue.length, (i) => i)..shuffle(_random);
    if (order.length > 1 && order.first == finished) {
      final swapWith = 1 + _random.nextInt(order.length - 1);
      final t = order[0];
      order[0] = order[swapWith];
      order[swapWith] = t;
    }
    _shuffleOrder = order;
    _currentIndex = order.first;
  }
}
