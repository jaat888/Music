// lib/services/like_service.dart
// Liked songs ka state manage karta hai — heart button isi se connect hoga.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../db/cache_db.dart';
import '../db/liked_db.dart';
import '../models/song.dart';

class LikeService extends ChangeNotifier {
  LikeService._internal();
  static final LikeService instance = LikeService._internal();

  final Set<String> _likedIds = {};
  bool _initialized = false;

  int likedCount = 0;

  // Pehli baar liked ids DB se load karo — app start pe ek baar call karna
  Future<void> init() async {
    if (_initialized) return;
    final liked = await LikedDB.instance.getAll();
    _likedIds
      ..clear()
      ..addAll(liked.map((s) => s.id));
    likedCount = _likedIds.length;
    _initialized = true;
    notifyListeners();
  }

  // Sync check ke liye cache use hota hai, isliye init() pehle ho chuka hona chahiye
  Future<bool> isLiked(String id) async {
    if (!_initialized) await init();
    return _likedIds.contains(id);
  }

  // Heart tap hone pe ye call hota hai — add/remove dono handle karta hai
  Future<void> toggleLike(Song song) async {
    if (!_initialized) await init();

    final willBeLiked = !_likedIds.contains(song.id);

    if (willBeLiked) {
      await LikedDB.instance.add(song);
      _likedIds.add(song.id);
      // Agar ye song cache me bhi hai to protected mark kar do — auto-delete se bach jayegi
      await CacheDB.instance.markProtected(song.id);
    } else {
      await LikedDB.instance.remove(song.id);
      _likedIds.remove(song.id);
      // Unlike hone pe protection hata do — ab normal LRU cache eligible hai
      await CacheDB.instance.update(song.id, protected: 0);
    }

    likedCount = _likedIds.length;
    HapticFeedback.mediumImpact();
    notifyListeners();
  }

  Future<List<Song>> getAllLiked() async {
    return LikedDB.instance.getAll();
  }
}
