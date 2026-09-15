// lib/services/queue_service.dart
// Sirf queue ka STATE rakhta hai — actual playback control Batch 5 ke
// audio handler se hoga, ye service usko sirf "kya bajna hai" batata hai.

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/song.dart';

enum SurRepeatMode { off, all, one }

class QueueService extends ChangeNotifier {
  QueueService._internal();
  static final QueueService instance = QueueService._internal();

  final List<Song> _queue = [];
  int _currentIndex = -1;
  bool _shuffle = false;
  SurRepeatMode _repeat = SurRepeatMode.off;

  // Shuffle on hone pe ye order use hota hai (original index list)
  List<int> _shuffleOrder = [];
  final _random = Random();

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

  // Current ke baad ke upcoming songs (queue screen me dikhane ke liye)
  List<Song> get upcoming {
    if (_currentIndex < 0 || _currentIndex >= _queue.length - 1) return [];
    return _queue.sublist(_currentIndex + 1);
  }

  // ---------------- Queue modify karna ----------------

  void add(Song song) {
    _queue.add(song);
    if (_currentIndex == -1) _currentIndex = 0;
    _rebuildShuffleOrder();
    notifyListeners();
  }

  void addAll(List<Song> songs) {
    _queue.addAll(songs);
    if (_currentIndex == -1 && _queue.isNotEmpty) _currentIndex = 0;
    _rebuildShuffleOrder();
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);

    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      // Current hi hata diya — index ko clamp kar do, agla song current ban jayega
      if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
    }
    _rebuildShuffleOrder();
    notifyListeners();
  }

  void clear() {
    _queue.clear();
    _currentIndex = -1;
    _shuffleOrder.clear();
    notifyListeners();
  }

  // Poori queue replace karke ek naye set se play shuru karo
  void setQueue(List<Song> songs, {int startIndex = 0}) {
    _queue
      ..clear()
      ..addAll(songs);
    _currentIndex = songs.isEmpty ? -1 : startIndex.clamp(0, songs.length - 1);
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

    final nextIndex = _currentIndex + 1;
    if (nextIndex < _queue.length) {
      _currentIndex = nextIndex;
    } else if (_repeat == SurRepeatMode.all) {
      _currentIndex = 0;
    }
    // repeat off aur queue khatam — currentIndex wahi rehta hai, player ruk jayega
    notifyListeners();
  }

  void previous() {
    if (_queue.isEmpty) return;
    final prevIndex = _currentIndex - 1;
    if (prevIndex >= 0) {
      _currentIndex = prevIndex;
    } else if (_repeat == SurRepeatMode.all) {
      _currentIndex = _queue.length - 1;
    }
    notifyListeners();
  }

  void jumpTo(int index) {
    if (index < 0 || index >= _queue.length) return;
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

    _rebuildShuffleOrder();
    notifyListeners();
  }

  // ---------------- Shuffle / Repeat ----------------

  void setShuffle(bool value) {
    _shuffle = value;
    _rebuildShuffleOrder();
    notifyListeners();
  }

  void setRepeat(SurRepeatMode mode) {
    _repeat = mode;
    notifyListeners();
  }

  void _rebuildShuffleOrder() {
    _shuffleOrder = List.generate(_queue.length, (i) => i)..shuffle(_random);
  }
}
