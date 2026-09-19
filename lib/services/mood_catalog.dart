// lib/services/mood_catalog.dart
// Discovery metadata only. Mood/Language pages fetch live YouTube Music
// playlists; they are deliberately NOT connected to Radio mode.

class MoodDefinition {
  final String code;
  final String label;
  final String emoji;
  final List<String> categoryAliases;
  final String fallbackQuery;

  const MoodDefinition({
    required this.code,
    required this.label,
    required this.emoji,
    required this.categoryAliases,
    required this.fallbackQuery,
  });
}

const List<MoodDefinition> kMoodDefinitions = [
  MoodDefinition(code: 'chill', label: 'Chill', emoji: '😌', categoryAliases: ['chill', 'chill out'], fallbackQuery: 'chill playlists'),
  MoodDefinition(code: 'feel_good', label: 'Feel Good', emoji: '😊', categoryAliases: ['feel good', 'feel-good'], fallbackQuery: 'feel good playlists'),
  MoodDefinition(code: 'romance', label: 'Romance', emoji: '❤️', categoryAliases: ['romance', 'romantic'], fallbackQuery: 'romantic playlists'),
  MoodDefinition(code: 'sad', label: 'Sad', emoji: '💔', categoryAliases: ['sad'], fallbackQuery: 'sad playlists'),
  MoodDefinition(code: 'party', label: 'Party', emoji: '🎉', categoryAliases: ['party', 'dance'], fallbackQuery: 'party playlists'),
  MoodDefinition(code: 'workout', label: 'Workout', emoji: '🔥', categoryAliases: ['workout', 'gym', 'fitness'], fallbackQuery: 'workout playlists'),
  MoodDefinition(code: 'focus', label: 'Focus', emoji: '🎯', categoryAliases: ['focus', 'concentration', 'study'], fallbackQuery: 'focus playlists'),
  MoodDefinition(code: 'sleep', label: 'Sleep', emoji: '🌙', categoryAliases: ['sleep', 'sleeping'], fallbackQuery: 'sleep playlists'),
  MoodDefinition(code: 'relax', label: 'Relax', emoji: '🧘', categoryAliases: ['relax', 'relaxation'], fallbackQuery: 'relax playlists'),
  MoodDefinition(code: 'motivation', label: 'Motivation', emoji: '💪', categoryAliases: ['motivation', 'motivational'], fallbackQuery: 'motivation playlists'),
  MoodDefinition(code: 'travel', label: 'Travel', emoji: '✈️', categoryAliases: ['travel', 'road trip', 'commute'], fallbackQuery: 'travel road trip playlists'),
  MoodDefinition(code: 'retro', label: 'Retro', emoji: '📻', categoryAliases: ['retro', 'oldies'], fallbackQuery: 'retro old songs playlists'),
  MoodDefinition(code: 'indie', label: 'Indie', emoji: '🎸', categoryAliases: ['indie'], fallbackQuery: 'indie playlists'),
  MoodDefinition(code: 'instrumental', label: 'Instrumental', emoji: '🎼', categoryAliases: ['instrumental'], fallbackQuery: 'instrumental playlists'),
];

class LanguageDefinition {
  final String code;
  final String label;
  final String nativeName;
  final String emoji;
  final String query;

  const LanguageDefinition({
    required this.code,
    required this.label,
    required this.nativeName,
    required this.emoji,
    required this.query,
  });
}

const List<LanguageDefinition> kMoodLanguages = [
  LanguageDefinition(code: 'hindi', label: 'Hindi', nativeName: 'हिन्दी', emoji: '🇮🇳', query: 'Hindi songs'),
  LanguageDefinition(code: 'punjabi', label: 'Punjabi', nativeName: 'ਪੰਜਾਬੀ', emoji: '🟠', query: 'Punjabi songs'),
  LanguageDefinition(code: 'haryanvi', label: 'Haryanvi', nativeName: 'हरियाणवी', emoji: '🟢', query: 'Haryanvi songs'),
  LanguageDefinition(code: 'english', label: 'English', nativeName: 'English', emoji: '🌐', query: 'English songs'),
  LanguageDefinition(code: 'tamil', label: 'Tamil', nativeName: 'தமிழ்', emoji: '🟣', query: 'Tamil songs'),
  LanguageDefinition(code: 'telugu', label: 'Telugu', nativeName: 'తెలుగు', emoji: '🔵', query: 'Telugu songs'),
  LanguageDefinition(code: 'bengali', label: 'Bengali', nativeName: 'বাংলা', emoji: '🟡', query: 'Bengali songs'),
  LanguageDefinition(code: 'marathi', label: 'Marathi', nativeName: 'मराठी', emoji: '🟤', query: 'Marathi songs'),
  LanguageDefinition(code: 'malayalam', label: 'Malayalam', nativeName: 'മലയാളം', emoji: '🟩', query: 'Malayalam songs'),
  LanguageDefinition(code: 'kannada', label: 'Kannada', nativeName: 'ಕನ್ನಡ', emoji: '🔴', query: 'Kannada songs'),
  LanguageDefinition(code: 'bhojpuri', label: 'Bhojpuri', nativeName: 'भोजपुरी', emoji: '🟧', query: 'Bhojpuri songs'),
  LanguageDefinition(code: 'gujarati', label: 'Gujarati', nativeName: 'ગુજરાતી', emoji: '🟦', query: 'Gujarati songs'),
  LanguageDefinition(code: 'rajasthani', label: 'Rajasthani', nativeName: 'राजस्थानी', emoji: '🟨', query: 'Rajasthani songs'),
  LanguageDefinition(code: 'urdu', label: 'Urdu', nativeName: 'اردو', emoji: '🟪', query: 'Urdu songs'),
  LanguageDefinition(code: 'assamese', label: 'Assamese', nativeName: 'অসমীয়া', emoji: '🟥', query: 'Assamese songs'),
];
