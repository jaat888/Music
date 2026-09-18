// lib/services/local_media_resolver.dart
//
// SINGLE SOURCE OF TRUTH: "ye gaana locally available hai kya, aur kahan
// (Download ya Cache)?" — pehle ye "DownloadDB.getFilePath(id) ??
// CacheDB.getFilePath(id)" priority-check 7 ALAG jagah copy-paste tha
// (background_service.dart me 3 baar, recently_played_screen.dart,
// mood_playlist_screen.dart, smart_playlist_screen.dart) — har jagah
// manually same order likha hua tha. Risk: koi nayi jagah agar copy-paste
// karte waqt order galat kar de (ya ek layer bhool jaaye), silently wrong
// behavior aata (jaise already-downloaded gaana phir bhi stream ho jaana).
// Ab sirf yahan se decide hota hai — priority badalni ho to SIRF yahan
// badlegi.
//
// NOTE: `duplicate_songs_screen.dart` jaanbujhke isse NAHI use karta —
// wahan Download aur Cache DONO independently check/delete hote hain
// (cleanup logic, "pehla match mil gaya to ruk jao" wala priority-read
// case nahi), isliye wo apna alag/correct pattern hi rakhta hai.
//
// Priority: Download (user ka explicit, permanent) > Cache (auto,
// evictable) — yahi order jo pehle har jagah manually tha, koi behavior
// change nahi kiya, sirf consolidate kiya hai.

import 'package:flutter/foundation.dart';

import '../db/cache_db.dart';
import '../db/download_db.dart';

enum LocalMediaSource { download, cache }

@immutable
class LocalMediaLocation {
  final String path;
  final LocalMediaSource source;
  const LocalMediaLocation(this.path, this.source);
}

class LocalMediaResolver {
  // TESTABILITY (2026-09-18): lookups function-fields ke through indirect
  // hain (default = asli DownloadDB/CacheDB), taaki `test/` me bina kisi
  // real sqlite/mocking-package ke, sirf fake functions pass karke priority
  // logic test ho sake. Runtime behavior bilkul same hai (production code
  // hamesha `LocalMediaResolver.instance` hi use karta hai, jo asli DBs se
  // wired hai) — sirf tests ke liye ek chhota seam add kiya.
  LocalMediaResolver._internal()
      : _downloadLookup = DownloadDB.instance.getFilePath,
        _cacheLookup = CacheDB.instance.getFilePath;

  static final LocalMediaResolver instance = LocalMediaResolver._internal();

  @visibleForTesting
  LocalMediaResolver.forTesting({
    required Future<String?> Function(String songId) downloadLookup,
    required Future<String?> Function(String songId) cacheLookup,
  })  : _downloadLookup = downloadLookup,
        _cacheLookup = cacheLookup;

  final Future<String?> Function(String songId) _downloadLookup;
  final Future<String?> Function(String songId) _cacheLookup;

  /// Sabse common case — bas file path chahiye (source irrelevant),
  /// jaise seedha isi se play karna hai.
  Future<String?> getPath(String songId) async {
    final location = await locate(songId);
    return location?.path;
  }

  /// Path + kahan se mila (Download ya Cache) — jab UI ko wo bhi batana ho.
  Future<LocalMediaLocation?> locate(String songId) async {
    final downloadPath = await _downloadLookup(songId);
    if (downloadPath != null) {
      return LocalMediaLocation(downloadPath, LocalMediaSource.download);
    }
    final cachePath = await _cacheLookup(songId);
    if (cachePath != null) {
      return LocalMediaLocation(cachePath, LocalMediaSource.cache);
    }
    return null;
  }

  /// Sirf boolean chahiye ho ("kya kahin locally available hai") to ye.
  Future<bool> isAvailableLocally(String songId) async {
    return (await getPath(songId)) != null;
  }
}
