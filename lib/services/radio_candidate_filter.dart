// Radio candidate hard gates — language, duration, and obvious cross-language leakage.
// These checks intentionally stay metadata-based: YouTube search results do not
// expose a trustworthy release-language classifier to the app.

import '../models/song.dart';

class RadioCandidateFilter {
  static const int maxDurationSeconds = 7 * 60;

  static final RegExp _gurmukhi = RegExp(r'[\u0A00-\u0A7F]');
  static final RegExp _word = RegExp(r"[^a-z0-9\u0900-\u097F\u0A00-\u0A7F]+", unicode: true);

  static bool durationAllowed(int durationSeconds) {
    // Radio ke liye unknown duration ko bhi reject karte hain: user ka rule
    // hard hai — koi 7 minute se upar ka track enter nahi hona chahiye.
    return durationSeconds > 0 && durationSeconds <= maxDurationSeconds;
  }

  static bool matchesStrictLanguage({
    required String language,
    required Song song,
  }) {
    final key = language.trim().toLowerCase();
    final text = '${song.title} ${song.artist}'.toLowerCase();
    final tokens = text
        .split(_word)
        .where((e) => e.trim().isNotEmpty)
        .toSet();

    bool hasAny(Iterable<String> values) =>
        values.any((value) => tokens.contains(value.toLowerCase()) ||
            text.contains(value.toLowerCase()));

    switch (key) {
      case 'haryanvi':
        // Strong Punjabi markers: Gurmukhi script or explicit Punjabi labels.
        // Roman-script songs cannot be classified perfectly from title/artist
        // alone, so query-level negative terms are also used by Radio.
        if (_gurmukhi.hasMatch(text)) return false;
        if (hasAny(const ['punjabi', 'ਪੰਜਾਬੀ'])) return false;
        return true;

      case 'punjabi':
        // Do not leak clearly-labelled Haryanvi material into Punjabi Radio.
        if (hasAny(const ['haryanvi', 'हरियाणवी', 'haryana'])) return false;
        return true;

      case 'bollywood':
        // Bollywood selection should not pull clearly-labelled regional tracks.
        if (_gurmukhi.hasMatch(text)) return false;
        if (hasAny(const ['punjabi', 'ਪੰਜਾਬੀ', 'haryanvi', 'हरियाणवी'])) {
          return false;
        }
        // Explicitly Devanagari content is still allowed (normal Hindi film
        // catalogue), so script alone is not used as a blocker here.
        return true;

      default:
        return true;
    }
  }
}
