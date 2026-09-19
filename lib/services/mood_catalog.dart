// lib/services/mood_catalog.dart
// Strict, shared mood metadata used by Mood mode's selector and Radio player.
// Mood eligibility is deliberately metadata-based: a candidate must carry at
// least one explicit mood keyword in its title/artist text. This avoids turning
// a broad YouTube search result into a false-positive mood recommendation.

class MoodProfile {
  final String code;
  final String label;
  final String emoji;
  final List<String> keywords;
  final List<String> querySeeds;

  const MoodProfile({
    required this.code,
    required this.label,
    required this.emoji,
    required this.keywords,
    required this.querySeeds,
  });

  String queryFor(
    String languageCode, {
    required bool latest,
    int seedIndex = 0,
  }) {
    final seed = querySeeds[seedIndex % querySeeds.length];
    final languageTerm = languageCode == 'bollywood'
        ? 'bollywood hindi'
        : languageCode;
    final ageHint = latest ? 'latest new' : 'popular hits';
    final negatives = <String>[];
    for (final other in const ['bollywood', 'punjabi', 'haryanvi']) {
      if (other != languageCode) negatives.add('-$other');
    }
    return '$ageHint $seed $languageTerm songs ${negatives.join(' ')}'.trim();
  }
}

const List<MoodProfile> kMoodProfiles = [
  MoodProfile(
    code: 'chill',
    label: 'Chill',
    emoji: '😌',
    keywords: [
      'chill', 'lofi', 'lo-fi', 'acoustic', 'unplugged', 'calm', 'soft',
      'soothing', 'relax', 'relaxed', 'ambient',
    ],
    querySeeds: ['chill lofi', 'chill acoustic', 'soft chill', 'relax lofi'],
  ),
  MoodProfile(
    code: 'workout',
    label: 'Workout',
    emoji: '🔥',
    keywords: [
      'workout', 'gym', 'pump', 'power', 'beast', 'energetic', 'energy',
      'motivation', 'motivational', 'josh', 'dhamaka', 'swag',
    ],
    querySeeds: ['workout gym', 'gym motivation', 'workout pump', 'energetic gym'],
  ),
  MoodProfile(
    code: 'party',
    label: 'Party',
    emoji: '🎉',
    keywords: [
      'party', 'dance', 'dj', 'remix', 'club', 'bhangra', 'masti', 'naach',
      'nach', 'jashn', 'night', 'upbeat',
    ],
    querySeeds: ['party dance', 'dj remix', 'club party', 'dance masti'],
  ),
  MoodProfile(
    code: 'sad',
    label: 'Sad',
    emoji: '💔',
    keywords: [
      'sad', 'breakup', 'break up', 'dard', 'judai', 'judaai', 'tanha',
      'tanhai', 'gham', 'bewafa', 'heartbreak', 'akela', 'akeli',
    ],
    querySeeds: ['sad breakup', 'dard judaai', 'sad heartbreak', 'bewafa dard'],
  ),
  MoodProfile(
    code: 'focus',
    label: 'Focus',
    emoji: '📚',
    keywords: [
      'focus', 'study', 'instrumental', 'lofi', 'lo-fi', 'ambient', 'calm',
      'concentration', 'relax', 'soft',
    ],
    querySeeds: ['focus study', 'instrumental lofi', 'study ambient', 'focus calm'],
  ),
];

MoodProfile? moodProfileByCode(String code) {
  final normalized = code.trim().toLowerCase();
  for (final mood in kMoodProfiles) {
    if (mood.code == normalized) return mood;
  }
  return null;
}

bool matchesStrictMood({required MoodProfile mood, required String title, required String artist}) {
  final haystack = _normalize('$title $artist');
  for (final keyword in mood.keywords) {
    final normalized = _normalize(keyword);
    if (normalized.isEmpty) continue;
    if (' $haystack '.contains(' $normalized ')) return true;
  }
  return false;
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
