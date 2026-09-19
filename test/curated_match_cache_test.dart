import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sursathi/models/song.dart';
import 'package:sursathi/services/curated_match_cache.dart';

Song _song(String id) => Song(
      id: id,
      title: 'T $id',
      artist: 'A $id',
      thumb: 'https://example.com/$id.jpg',
      duration: 200,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('matched song survives a fresh cache instance (persisted to disk)', () async {
    final a = CuratedMatchCache();
    await a.ensureLoaded();
    a.put('Tum Hi Ho', 'Arijit Singh', _song('abc'));
    await a.flush();

    final b = CuratedMatchCache();
    await b.ensureLoaded();
    expect(b.get('Tum Hi Ho', 'Arijit Singh')?.id, 'abc');
  });

  test('key ignores case and extra spaces', () async {
    final c = CuratedMatchCache();
    await c.ensureLoaded();
    c.put('Tum  Hi Ho', 'ARIJIT singh', _song('abc'));
    expect(c.get('tum hi ho', 'Arijit Singh')?.id, 'abc');
  });

  test('unknown track is a miss', () async {
    final c = CuratedMatchCache();
    await c.ensureLoaded();
    expect(c.get('Nothing', 'Nobody'), isNull);
  });

  test('entries expire after maxAge', () async {
    var now = DateTime(2026, 9, 19);
    final c = CuratedMatchCache(clock: () => now);
    await c.ensureLoaded();
    c.put('Song', 'Artist', _song('x1'));
    expect(c.get('Song', 'Artist')?.id, 'x1');
    now = now.add(CuratedMatchCache.maxAge + const Duration(days: 1));
    expect(c.get('Song', 'Artist'), isNull);
  });
}
