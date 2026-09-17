// lib/services/radio_engine.dart
// Part 8 (Radio Mode) — hardened candidate pool + natural weighted selection.
// Radio keeps the 150-day exact-song exclusion hard, while old/new/hit/latest
// signals stay soft so the sequence remains varied rather than 60/40-patterned.

import 'dart:math' as math;

import '../models/song.dart';
import 'radio_history_store.dart';
import 'radio_service.dart';
import 'radio_tagging.dart';

class RadioCandidate {
  final Song song;
  final String language;
  final List<String> tags;
  final double popularity;
  final double recency;
  final bool isLatest;

  const RadioCandidate({
    required this.song,
    required this.language,
    required this.tags,
    this.popularity = 0,
    this.recency = 0,
    this.isLatest = false,
  });

  RadioCandidate copyWith({
    double? popularity,
    double? recency,
    bool? isLatest,
  }) {
    return RadioCandidate(
      song: song,
      language: language,
      tags: tags,
      popularity: popularity ?? this.popularity,
      recency: recency ?? this.recency,
      isLatest: isLatest ?? this.isLatest,
    );
  }

  factory RadioCandidate.fromSong(
    Song song, {
    required String language,
    String? categoryHint,
    double popularity = 0,
    double recency = 0,
    bool isLatest = false,
  }) {
    return RadioCandidate(
      song: song,
      language: language,
      tags: tagSong(song, categoryHint: categoryHint),
      popularity: popularity,
      recency: recency,
      isLatest: isLatest,
    );
  }
}

class RadioEngine {
  RadioEngine({
    RadioHistoryStore? historyStore,
    RadioService? radioService,
    math.Random? random,
  })  : _history = historyStore ?? RadioHistoryStore.instance,
        _radio = radioService ?? RadioService.instance,
        _random = random ?? math.Random();

  final RadioHistoryStore _history;
  final RadioService _radio;
  final math.Random _random;

  // Search rank is deliberately a weak hint. Natural old/new mixing is driven
  // by soft score signals; there is no fixed 60/40 bucket filter anymore.
  static const double popularityWeight = 8;
  static const double recencyWeight = 10;
  static const double moodWeight = 0.18;
  static const double latestSoftBoost = 1.5;
  static const double randomJitter = 2.5;
  static const double scoreFloor = 0.1;

  /// Builds the eligible pool. Recent exact song IDs are a hard exclusion.
  /// We intentionally never fall back to a recently-played item: doing so
  /// would violate the 150-day rule. If a language is exhausted, it simply
  /// contributes no candidates until more eligible material is fetched.
  List<RadioCandidate> buildPool(
    Iterable<RadioCandidate> candidates, {
    required List<String> selectedLanguages,
  }) {
    final languages = selectedLanguages
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (languages.isEmpty) return const [];

    final all = candidates
        .where((c) => languages.contains(c.language.trim().toLowerCase()))
        .toList();
    if (all.isEmpty) return const [];

    final result = <RadioCandidate>[];
    for (final language in languages) {
      final items = all
          .where((c) => c.language.trim().toLowerCase() == language)
          .toList();
      if (items.isEmpty) continue;

      final fresh = items
          .where((c) => !_history.wasPlayedRecently(c.song.id))
          .toList();
      // Keep the exact-song 150-day exclusion hard. Do not re-add `items`
      // when `fresh` is empty and do not use a global oldest-ID shortcut.
      result.addAll(fresh);
    }
    return result;
  }

  /// Picks a queue-ahead buffer. Each chosen ID is excluded from the next
  /// pick so the upcoming list cannot contain duplicates.
  List<RadioCandidate> buildLookAhead(
    Iterable<RadioCandidate> candidates, {
    required List<String> selectedLanguages,
    int count = 4,
    Set<String> excludeIds = const {},
  }) {
    final result = <RadioCandidate>[];
    final used = <String>{...excludeIds};
    final source = candidates.toList();

    for (var i = 0; i < count; i++) {
      final next = pickNext(
        source,
        selectedLanguages: selectedLanguages,
        excludeIds: used,
      );
      if (next == null) break;
      result.add(next);
      used.add(next.song.id);
    }
    return result;
  }

  /// Weighted random pick after ALL eligible candidates are assembled.
  /// Language share, mood, popularity and recency are soft influences only.
  RadioCandidate? pickNext(
    Iterable<RadioCandidate> candidates, {
    required List<String> selectedLanguages,
    Set<String> excludeIds = const {},
  }) {
    final pool = buildPool(
      candidates,
      selectedLanguages: selectedLanguages,
    ).where((c) => !excludeIds.contains(c.song.id)).toList();
    if (pool.isEmpty) return null;

    final languageSet = selectedLanguages
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    final targetShare = languageSet.isEmpty ? 1.0 : 1.0 / languageSet.length;

    final weights = <double>[];
    for (final candidate in pool) {
      final tags = candidate.tags.isEmpty ? const ['mixed'] : candidate.tags;
      final moodSum = tags.fold<double>(
        0,
        (sum, tag) => sum + _radio.effectiveScore(tag),
      );
      final moodAverage = moodSum / tags.length;
      final moodDelta = moodAverage - RadioService.kNeutralScore;

      final language = candidate.language.trim().toLowerCase();
      final languageBoost = _languageWeight(pool, language, targetShare);

      // `popularity` is only a search-rank proxy, so it stays deliberately
      // small. `recency` is continuous within the latest search batch and is
      // also a soft hint, never an eligibility gate.
      var score = 35.0;
      score += _clamp01(candidate.popularity) * popularityWeight;
      score += _clamp01(candidate.recency) * recencyWeight;
      score += moodDelta * moodWeight;
      score += languageBoost;
      if (candidate.isLatest) score += latestSoftBoost;
      score += (_random.nextDouble() * 2 - 1) * randomJitter;

      weights.add(math.max(scoreFloor, score));
    }

    return pool[_weightedIndex(weights)];
  }

  double _languageWeight(
    List<RadioCandidate> pool,
    String language,
    double targetShare,
  ) {
    if (pool.isEmpty) return 0;
    final count = pool
        .where((c) => c.language.trim().toLowerCase() == language)
        .length;
    if (count == 0) return 0;
    final actualShare = count / pool.length;
    return (targetShare - actualShare) * 12;
  }

  int _weightedIndex(List<double> weights) {
    final total = weights.fold<double>(0, (sum, w) => sum + w);
    if (total <= 0) return _random.nextInt(weights.length);
    var cursor = _random.nextDouble() * total;
    for (var i = 0; i < weights.length; i++) {
      cursor -= weights[i];
      if (cursor <= 0) return i;
    }
    return weights.length - 1;
  }

  double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();
}
