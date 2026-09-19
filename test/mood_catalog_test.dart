import 'package:flutter_test/flutter_test.dart';
import '../lib/services/mood_catalog.dart';
import '../lib/screens/radio_language_select_screen.dart';

void main() {
  test('strict mood accepts explicit mood keyword', () {
    final mood = moodProfileByCode('sad')!;
    expect(matchesStrictMood(mood: mood, title: 'Sad Breakup Song', artist: 'Singer'), isTrue);
  });

  test('strict mood rejects unrelated metadata', () {
    final mood = moodProfileByCode('sad')!;
    expect(matchesStrictMood(mood: mood, title: 'Tum Hi Ho', artist: 'Arijit Singh'), isFalse);
  });

  test('mood query carries the selected language and negative regional guards', () {
    final mood = moodProfileByCode('chill')!;
    final bollywood = mood.queryFor(
      RadioLanguageSelectScreen.languages.first.code,
      latest: true,
      seedIndex: 0,
    );
    expect(bollywood.contains('bollywood hindi'), isTrue);
    expect(bollywood.contains('-punjabi'), isTrue);
    expect(bollywood.contains('-haryanvi'), isTrue);
  });
}
