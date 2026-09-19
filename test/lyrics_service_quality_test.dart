import 'package:flutter_test/flutter_test.dart';

import 'package:sursathi/services/lyrics_service.dart';

void main() {
  test('timed lyric word segments get a visible space between words', () {
    expect(
      LyricsService.joinTimedSegmentsForTest(const ['mera', 'dil', 'yeh']),
      'mera dil yeh',
    );
  });

  test('punctuation does not get an extra leading space', () {
    expect(
      LyricsService.joinTimedSegmentsForTest(
        const ['hello', ', duniya', '!'],
      ),
      'hello, duniya!',
    );
  });

  test('timed quality favours lyrics that cover more of the song', () {
    final short = [
      const LyricLine(Duration(seconds: 0), 'a'),
      const LyricLine(Duration(seconds: 20), 'b'),
    ];
    final complete = [
      const LyricLine(Duration(seconds: 0), 'a'),
      const LyricLine(Duration(seconds: 80), 'b'),
      const LyricLine(Duration(seconds: 170), 'c'),
    ];
    expect(
      LyricsService.syncedQualityScoreForTest(short, 180),
      lessThan(LyricsService.syncedQualityScoreForTest(complete, 180)),
    );
  });
}
