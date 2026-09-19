import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sursathi/models/song.dart';
import 'package:sursathi/services/radio_engine.dart';
import 'package:sursathi/services/radio_history_store.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RadioHistoryStore.instance.init();
    await RadioHistoryStore.instance.clear();
  });

  test('legacy history receives useful completion defaults', () {
    final entry = RadioHistoryEntry.fromJson({
      'songId': 'abc',
      'title': 'Song',
      'language': 'hi',
      'duration': 180,
      'playedAt': 1,
      'wasSkipped': false,
    });
    expect(entry.listenSeconds, 180);
    expect(entry.completionRatio, 1);
    expect(entry.replayCount, 0);
  });

  test('skip timing is learned from the actual second of the skip', () async {
    await RadioHistoryStore.instance.record(
      songId: 'abc',
      title: 'Song',
      artist: 'Artist A',
      language: 'hi',
      tags: const ['romantic'],
      duration: 200,
      wasSkipped: true,
      skipPositionSec: 8,
    );
    final signal = RadioHistoryStore.instance.tagSkipTimingAffinity()['romantic'];
    expect(signal, closeTo(-1.0, 0.001));
  });

  test('recent artist counts include persisted plays inside the 45-minute window', () async {
    await RadioHistoryStore.instance.record(
      songId: 'artist-song',
      title: 'Song',
      artist: 'Artist A',
      language: 'hi',
      tags: const ['romantic'],
      duration: 180,
      wasSkipped: false,
    );
    final counts = RadioHistoryStore.instance.recentArtistCounts(
      within: const Duration(minutes: 45),
    );
    expect(counts['artist a'], 1);
  });

  test('skipped timing is not double-counted in generic tag/artist affinity', () async {
    await RadioHistoryStore.instance.record(
      songId: 'skip-song',
      title: 'Skipped Song',
      artist: 'Artist A',
      language: 'hi',
      tags: const ['romantic'],
      duration: 200,
      wasSkipped: true,
      skipPositionSec: 8,
    );

    expect(RadioHistoryStore.instance.tagAffinity()['romantic'], isNull);
    expect(RadioHistoryStore.instance.artistAffinity()['artist a'], isNull);
    expect(
      RadioHistoryStore.instance.tagSkipTimingAffinity()['romantic'],
      closeTo(-1.0, 0.001),
    );
    expect(
      RadioHistoryStore.instance.artistSkipTimingAffinity()['artist a'],
      closeTo(-1.0, 0.001),
    );
  });

  test('replay is retained as a positive learning signal', () async {
    await RadioHistoryStore.instance.record(
      songId: 'abc',
      title: 'Song',
      artist: 'Artist A',
      language: 'hi',
      tags: const ['romantic'],
      duration: 200,
      wasSkipped: false,
    );
    await RadioHistoryStore.instance.markLatestAsCompleted(
      songId: 'abc',
      listenSeconds: 200,
      duration: 200,
    );
    await RadioHistoryStore.instance.markReplay('abc');
    final entry = RadioHistoryStore.instance.entries.single;
    expect(entry.replayCount, 1);
    expect(RadioHistoryStore.instance.artistAffinity()['artist a'], closeTo(1.35, 0.001));
  });

  test('candidate construction keeps radio tags', () {
    final song = Song(
      id: 'abc',
      title: 'Soft Romantic Song',
      artist: 'A',
      thumb: '',
      duration: 180,
    );
    final candidate = RadioCandidate.fromSong(song, language: 'hi');
    expect(candidate.tags, contains('romantic'));
  });
}
