// lib/services/radio_tagging.dart
// Part 8 (Radio Mode) — Phase 1 hardened keyword tagging.

import '../models/song.dart';

const Map<String, List<String>> kRadioTagKeywords = {
  'sad': [
    'sad', 'dard', 'dard-e-dil', 'judai', 'judaai', 'tanha', 'tanhai',
    'gham', 'bewafa', 'yaad', 'yaadein', 'rona', 'aansu', 'dukh',
    'akela', 'akeli', 'bichhad', 'bichhadna', 'khoya', 'khona',
  ],
  'romantic': [
    'romantic', 'pyaar', 'pyar', 'ishq', 'mohabbat', 'love', 'dil',
    'deewana', 'deewani', 'chahat', 'chaahat', 'saathiya', 'jaana',
    'jaaneman', 'mehbooba', 'mehboob', 'crush', 'dilbar',
  ],
  'breakup': [
    'breakup', 'break up', 'bewafa', 'dhokha', 'judaai', 'judai',
    'alvida', 'tanhai', 'chhod', 'chhoda', 'chhodna', 'juda',
  ],
  'party': [
    'party', 'dj', 'remix', 'dance floor', 'nasha', 'jashn', 'zid',
    'badshah', 'club', 'night', 'masti', 'daaru',
  ],
  'dance': [
    'dance', 'nach', 'nachna', 'thumka', 'item', 'beat', 'bhangra',
    'garba', 'dandiya', 'naach',
  ],
  'energetic': [
    'energetic', 'josh', 'high', 'power', 'jashn', 'dhamaal', 'dhamaka',
    'entry', 'swag', 'attitude', 'desi',
  ],
  'slow': [
    'slow', 'unplugged', 'acoustic', 'lofi', 'lo-fi', 'chill',
    'soft', 'soothing', 'lullaby', 'lori',
  ],
  'devotional': [
    'bhakti', 'devotional', 'bhajan', 'aarti', 'mantra', 'chalisa',
    'bhagwan', 'shiv', 'krishna', 'ram', 'hanuman', 'durga', 'mata',
    'gurbani', 'kirtan',
  ],
  'wedding': [
    'wedding', 'shaadi', 'shadi', 'vivah', 'sangeet', 'mehendi',
    'mehndi', 'baraat', 'dulha', 'dulhan', 'banna', 'banni',
  ],
};

String _normalize(String value) {
  // Keep letters/numbers/whitespace; turn punctuation (including '-'/'/')
  // into spaces so phrases like "dard-e-dil" still match as whole phrases.
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

bool _containsWholePhrase(String haystack, String keyword) {
  final h = ' ${_normalize(haystack)} ';
  final k = ' ${_normalize(keyword)} ';
  return k.length > 2 && h.contains(k);
}

List<String> tagSong(Song song, {String? categoryHint}) {
  final haystack = '${song.title} ${categoryHint ?? ''}';
  final tags = <String>{};

  for (final entry in kRadioTagKeywords.entries) {
    for (final keyword in entry.value) {
      if (_containsWholePhrase(haystack, keyword)) {
        tags.add(entry.key);
        break;
      }
    }
  }

  if (tags.isEmpty) tags.add('mixed');
  return tags.toList(growable: false);
}

List<String> get kAllRadioTags => [...kRadioTagKeywords.keys, 'mixed'];
