import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/services/radio_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('concurrent Radio history records do not lose entries', () async {
    final store = RadioHistoryStore.instance;
    await store.clear();

    await Future.wait(
      List.generate(
        12,
        (i) => store.record(
          songId: 'song-$i',
          title: 'Song $i',
          tags: const ['mixed'],
          language: 'hi',
          artist: 'Artist $i',
          duration: 180,
          wasSkipped: true,
          skipPositionSec: 20 + i,
        ),
      ),
    );

    expect(store.entries.length, 12);
    expect(store.entries.map((e) => e.songId).toSet().length, 12);
  });
}
