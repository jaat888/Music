import 'package:flutter_test/flutter_test.dart';
import 'package:sursathi/models/song.dart';
import 'package:sursathi/services/radio_candidate_filter.dart';

Song song({required String title, String artist = 'Artist', int duration = 180}) {
  return Song(
    id: title,
    title: title,
    artist: artist,
    thumb: '',
    duration: duration,
  );
}

void main() {
  test('Radio hard duration gate rejects unknown and over-7-minute tracks', () {
    expect(RadioCandidateFilter.durationAllowed(0), isFalse);
    expect(RadioCandidateFilter.durationAllowed(421), isFalse);
    expect(RadioCandidateFilter.durationAllowed(420), isTrue);
  });

  test('Haryanvi strict gate rejects obvious Punjabi metadata leakage', () {
    expect(
      RadioCandidateFilter.matchesStrictLanguage(
        language: 'haryanvi',
        song: song(title: 'Punjabi Song', artist: 'Artist'),
      ),
      isFalse,
    );
    expect(
      RadioCandidateFilter.matchesStrictLanguage(
        language: 'haryanvi',
        song: song(title: 'ਪੰਜਾਬੀ ਗਾਣਾ', artist: 'Artist'),
      ),
      isFalse,
    );
  });

  test('Haryanvi regular Devanagari title remains eligible', () {
    expect(
      RadioCandidateFilter.matchesStrictLanguage(
        language: 'haryanvi',
        song: song(title: 'हरियाणवी गाना', artist: 'Artist'),
      ),
      isTrue,
    );
  });
}
