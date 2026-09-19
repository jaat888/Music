import 'package:flutter_test/flutter_test.dart';
import 'package:sursathi/services/mood_catalog.dart';

void main() {
  test('mood catalog contains requested discovery moods', () {
    final labels = kMoodDefinitions.map((m) => m.label).toSet();
    expect(labels, containsAll(['Chill', 'Feel Good', 'Romance', 'Sad', 'Party', 'Workout', 'Focus', 'Sleep', 'Relax', 'Motivation', 'Travel', 'Retro']));
  });

  test('language catalog contains requested languages', () {
    final labels = kMoodLanguages.map((l) => l.label).toSet();
    expect(labels, containsAll(['Hindi', 'Punjabi', 'Haryanvi', 'English', 'Tamil', 'Telugu', 'Bengali', 'Marathi']));
  });
}
