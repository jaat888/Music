// lib/services/radio_engine.dart
// SurSathi v55 Radio Enhanced — natural weighted Radio selection.
// The engine owns the session-level failed set and liked-song weighting so the
// UI can ask for the next candidate without creating a second Radio pipeline.

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

  // Soft signals only. There is deliberately no fixed old/new bucket split.
  static const double popularityWeight = 8;
  static const double recencyWeight = 10;
  static const double moodWeight = 0.18;
  static const double likedWeight = 9;
  // Likes receive a soft boost only after their cooldown has elapsed; the
  // hard 150-day exact-song repeat rule still applies independently.
  static const Duration likedBoostCooldown = Duration(hours: 12);
  static const double latestSoftBoost = 1.5;
  static const double randomJitter = 2.5;
  // Adaptive behaviour layer: listening history gently changes future picks.
  static const double behaviourWeight = 3.5;
  static const double artistWeight = 2.5;
  static const double languageAffinityWeight = 1.5;
  static const double explorationWeight = 1.2;
  static const double scoreFloor = 0.1;

  // Radio-session failures are hard blocked until the screen/session is reset.
  final Set<String> _failedSessionIds = <String>{};
  final Set<String> _likedIds = <String>{};
  final Map<String, DateTime> _likedPlayedAt = <String, DateTime>{};

  Set<String> get failedSessionIds => Set.unmodifiable(_failedSessionIds);

  void markFailed(String songId) {
    if (songId.isNotEmpty) _failedSessionIds.add(songId);
  }

  void clearFailed() => _failedSessionIds.clear();

  void setLikedIds(Iterable<String> ids) {
    _likedIds
      ..clear()
      ..addAll(ids.where((id) => id.isNotEmpty));
  }

  void setLiked(String songId, bool liked) {
    if (liked) {
      _likedIds.add(songId);
    } else {
      _likedIds.remove(songId);
      _likedPlayedAt.remove(songId);
    }
  }

  void markPlayed(String songId) {
    if (_likedIds.contains(songId)) {
      _likedPlayedAt[songId] = DateTime.now();
    }
  }

  List<RadioCandidate> buildPool(
    Iterable<RadioCandidate> candidates, {
    required List<String> selectedLanguages,
  }) {
    final languages = selectedLanguages
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (languages.isEmpty) return const [];

    return candidates
        .where((c) => languages.contains(c.language.trim().toLowerCase()))
        // 150-day exact-song exclusion remains hard.
        .where((c) => !_history.wasPlayedRecently(c.song.id))
        // A failed Radio candidate cannot reappear during this session.
        .where((c) => !_failedSessionIds.contains(c.song.id))
        .toList();
  }

  List<RadioCandidate> buildLookAhead(
    Iterable<RadioCandidate> candidates, {
    required List<String> selectedLanguages,
    int count = 10,
    Set<String> excludeIds = const {},
    Map<String, int> recentLanguageCounts = const {},
  }) {
    final result = <RadioCandidate>[];
    final used = <String>{...excludeIds, ..._failedSessionIds};
    final source = candidates.toList();

    for (var i = 0; i < count; i++) {
      final next = pickNext(
        source,
        selectedLanguages: selectedLanguages,
        excludeIds: used,
        recentLanguageCounts: recentLanguageCounts,
      );
      if (next == null) break;
      result.add(next);
      used.add(next.song.id);
    }
    return result;
  }

  /// Order of influence:
  /// eligible pool -> mood -> liked boost -> skip-derived mood penalty ->
  /// language balance -> old/new soft signals -> small randomness -> weighted pick.
  RadioCandidate? pickNext(
    Iterable<RadioCandidate> candidates, {
    required List<String> selectedLanguages,
    Set<String> excludeIds = const {},
    Map<String, int> recentLanguageCounts = const {},
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
    // Build persisted behaviour aggregates once per selection pass, not once
    // per candidate. This keeps Radio ranking cheap even with large pools.
    final tagAffinity = _history.tagAffinity();
    final artistAffinity = _history.artistAffinity();
    final languageAffinity = _history.languageAffinity();
    for (final candidate in pool) {
      // 1) Mood score, including the existing temporary skip penalty.
      final tags = candidate.tags.isEmpty ? const ['mixed'] : candidate.tags;
      final moodAverage = tags
              .map(_radio.effectiveScore)
              .fold<double>(0, (sum, score) => sum + score) /
          tags.length;
      final moodDelta = moodAverage - RadioService.kNeutralScore;

      var score = 35.0 + moodDelta * moodWeight;

      // 2) Liked songs get a weighted boost only; liking never makes a hard
      // repeat eligible and never forces a song to the front.
      if (_likedIds.contains(candidate.song.id) && _likeBoostReady(candidate.song.id)) {
        score += likedWeight;
      }

      // 3) Behaviour learning: completion/skip history teaches Radio what
      // the listener actually enjoys, even when they never press Like.
      final songAffinity = _history.songAffinity(candidate.song.id);
      final language = candidate.language.trim().toLowerCase();
      final tagSignal = tags.fold<double>(0, (sum, tag) => sum + (tagAffinity[tag] ?? 0)) / tags.length;
      final artistSignal = artistAffinity[candidate.song.artist.trim().toLowerCase()] ?? 0;
      final languageSignal = languageAffinity[language] ?? 0;
      score += _boundedBehaviour(tagSignal + songAffinity * .5) * behaviourWeight;
      score += _boundedBehaviour(artistSignal) * artistWeight;
      score += _boundedBehaviour(languageSignal) * languageAffinityWeight;

      // 4) Search-rank popularity and latest/newness remain soft hints.
      score += _clamp01(candidate.popularity) * popularityWeight;
      score += _clamp01(candidate.recency) * recencyWeight;
      if (candidate.isLatest) score += latestSoftBoost;

      // 5) Give unseen candidates a small exploration bonus so Radio can
      // discover new artists instead of becoming an echo chamber.
      if (artistSignal == 0 && tagSignal == 0 && songAffinity == 0) {
        score += explorationWeight;
      }

      // 6) Language balance is session-aware, not a fixed ratio/bucket.
      score += _languageWeight(
        pool,
        language,
        targetShare,
        recentLanguageCounts,
      );

      // 7) Keep the weighted random nature of Radio.
      score += (_random.nextDouble() * 2 - 1) * randomJitter;
      weights.add(math.max(scoreFloor, score));
    }

    return pool[_weightedIndex(weights)];
  }


  bool _likeBoostReady(String songId) {
    final playedAt = _likedPlayedAt[songId];
    if (playedAt == null) return true;
    return DateTime.now().difference(playedAt) >= likedBoostCooldown;
  }

  double _languageWeight(
    List<RadioCandidate> pool,
    String language,
    double targetShare,
    Map<String, int> recentLanguageCounts,
  ) {
    if (pool.isEmpty) return 0;
    final totalRecent = recentLanguageCounts.values.fold<int>(0, (a, b) => a + b);
    if (totalRecent > 0) {
      final used = recentLanguageCounts[language] ?? 0;
      final minUsed = pool
          .map((c) => recentLanguageCounts[c.language.trim().toLowerCase()] ?? 0)
          .fold<int>(1 << 30, (a, b) => math.min(a, b));
      // Prefer languages that have been less represented recently, but keep it
      // deliberately small so mood/likes still have a real effect.
      if (used == minUsed) return 5.0;
      return -math.min(5.0, (used - minUsed).toDouble() * 1.5);
    }

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

  double _boundedBehaviour(double value) => value.clamp(-4.0, 4.0).toDouble();
}
