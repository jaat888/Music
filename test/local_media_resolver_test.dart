// test/local_media_resolver_test.dart
//
// Isse pehle poore codebase me EK bhi test nahi tha. Ye "Download >
// Cache" priority-check ka test hai — wahi logic jo pehle 7 alag jagah
// copy-paste tha (dekho lib/services/local_media_resolver.dart ka top
// comment) ab ek hi jagah hai, isliye ek hi test-file se poore app ke
// "local file kahan se milega" behavior ki guarantee milti hai.
//
// Real DownloadDB/CacheDB (sqflite) use nahi kiya — unke liye ek real
// SQLite engine (sqflite_common_ffi) chahiye hota, jo is test ke maksad
// (priority-ORDER sahi hai ya nahi) ke liye zaroori nahi hai. Iske bajaye
// simple fake lookup-functions inject kiye hain
// (`LocalMediaResolver.forTesting`) — fast, koi DB setup nahi, sirf
// asli logic (jo bug-prone hissa hai) test hota hai.
//
// Chalane ke liye: `flutter test`

import 'package:flutter_test/flutter_test.dart';
import 'package:sursathi/services/local_media_resolver.dart';

void main() {
  group('LocalMediaResolver — Download vs Cache priority', () {
    test('download me mile to wahi mile, cache check hi na ho', () async {
      var cacheLookupCalled = false;
      final resolver = LocalMediaResolver.forTesting(
        downloadLookup: (id) async => '/downloads/$id.m4a',
        cacheLookup: (id) async {
          cacheLookupCalled = true;
          return '/cache/$id.m4a';
        },
      );

      final location = await resolver.locate('song1');

      expect(location, isNotNull);
      expect(location!.path, '/downloads/song1.m4a');
      expect(location.source, LocalMediaSource.download);
      // Download hi mil gaya — cache lookup se koi extra disk/DB call
      // waste nahi honi chahiye.
      expect(cacheLookupCalled, isFalse);
    });

    test('download me na mile, cache me mile to cache wala mile', () async {
      final resolver = LocalMediaResolver.forTesting(
        downloadLookup: (id) async => null,
        cacheLookup: (id) async => '/cache/$id.m4a',
      );

      final location = await resolver.locate('song2');

      expect(location, isNotNull);
      expect(location!.path, '/cache/song2.m4a');
      expect(location.source, LocalMediaSource.cache);
    });

    test('dono me na mile to null aana chahiye', () async {
      final resolver = LocalMediaResolver.forTesting(
        downloadLookup: (id) async => null,
        cacheLookup: (id) async => null,
      );

      expect(await resolver.locate('song3'), isNull);
      expect(await resolver.getPath('song3'), isNull);
      expect(await resolver.isAvailableLocally('song3'), isFalse);
    });

    test('getPath() sirf path deta hai, source nahi', () async {
      final resolver = LocalMediaResolver.forTesting(
        downloadLookup: (id) async => null,
        cacheLookup: (id) async => '/cache/song4.m4a',
      );

      expect(await resolver.getPath('song4'), '/cache/song4.m4a');
    });

    test('isAvailableLocally() true hai jab dono me se koi ek bhi mile',
        () async {
      final downloadHit = LocalMediaResolver.forTesting(
        downloadLookup: (id) async => '/downloads/x.m4a',
        cacheLookup: (id) async => null,
      );
      final cacheHit = LocalMediaResolver.forTesting(
        downloadLookup: (id) async => null,
        cacheLookup: (id) async => '/cache/x.m4a',
      );

      expect(await downloadHit.isAvailableLocally('x'), isTrue);
      expect(await cacheHit.isAvailableLocally('x'), isTrue);
    });

    test('har call ko sahi songId forward hona chahiye (galat id se '
        'match na ho)', () async {
      String? receivedDownloadId;
      String? receivedCacheId;
      final resolver = LocalMediaResolver.forTesting(
        downloadLookup: (id) async {
          receivedDownloadId = id;
          return null;
        },
        cacheLookup: (id) async {
          receivedCacheId = id;
          return null;
        },
      );

      await resolver.locate('specific-song-id-123');

      expect(receivedDownloadId, 'specific-song-id-123');
      expect(receivedCacheId, 'specific-song-id-123');
    });
  });
}
