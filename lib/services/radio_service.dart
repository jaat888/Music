// lib/services/radio_service.dart
// Part 8 (Radio Mode) — Phase 2: mood-score session state + radio_session.
// Standalone file, koi protected pipeline file touch nahi hua.
//
// Roadmap section 3.2 (`radio_mood_scores`) aur 3.3 (`radio_session`).
// Session-level, in-memory only (open question section 12 resolved:
// "session-only by default" — app/radio dobara khole to fresh scores).
//
// Selection algorithm (candidate pool + weighted pick) Phase 3 ka kaam hai
// (`radio_engine.dart`) — yahan sirf score state + roadmap section 4 ka
// decay formula hai, taaki Phase 3 seedha `effectiveScore()` call kar sake.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

class RadioService extends ChangeNotifier {
  RadioService._internal();
  static final RadioService instance = RadioService._internal();

  // Roadmap section 4.1/4.4 tuning constants (section 12: "starting point
  // diya gaya hai, real usage ke baad adjust hoga").
  static const double kNeutralScore = 100;
  static const double kSkipPenalty = 15;
  static const double kFavoriteBoost = 10;
  // Part 11 tuning: keep the roadmap starting values explicit and centralized.
  static const Duration kSessionHistoryWindow = Duration(days: 90);
  static const Duration kDecayConstant = Duration(minutes: 27);
  // Section 4.3: lagatar 2-3 skip ke baad extra penalty ("jaise double").
  static const int kEscalationThreshold = 2;
  static const double kEscalationMultiplier = 2;

  // tag -> positive preference score (favorites raise this value).
  final Map<String, double> _baseScores = {};
  // tag -> currently active temporary skip penalty. This is kept separate
  // from the base score so even escalated penalties can fully recover.
  final Map<String, double> _activePenalties = {};
  // tag -> last skip time (decay/recovery starts here).
  final Map<String, DateTime> _lastSkippedAt = {};
  // tag -> lagatar kitni baar skip hua (poora sunte/na-skip karte hi reset)
  final Map<String, int> _consecutiveSkips = {};
  final Map<String, int> _favoriteBoostCounts = {};

  // radio_session (section 3.3)
  List<String> _selectedLanguages = [];
  List<String> get selectedLanguages => List.unmodifiable(_selectedLanguages);

  void setSelectedLanguages(List<String> languages) {
    _selectedLanguages = List<String>.from(languages);
    notifyListeners();
  }

  double _baseScoreFor(String tag) => _baseScores[tag] ?? kNeutralScore;

  /// Roadmap section 4.2 — exponential decay/recovery formula:
  /// `effective = base - penalty + penalty*(1 - e^(-elapsed/decayConstant))`
  /// Skip abhi hua ho to poora penalty lagta hai; jitna time beetta hai
  /// utna hi recover hota hai (~63% ~27 min me, ~95%+ ~1.5-2 ghante me).
  /// Kabhi skip hi nahi hua tag ke liye seedha neutral/base score milta hai.
  double effectiveScore(String tag) {
    final base = _baseScoreFor(tag);
    final penalty = _activePenalties[tag] ?? 0;
    final lastSkip = _lastSkippedAt[tag];
    if (lastSkip == null || penalty <= 0) return base;

    final elapsedMinutes = DateTime.now().difference(lastSkip).inSeconds / 60.0;
    final decayConstantMinutes = kDecayConstant.inSeconds / 60.0;
    final remaining = penalty * math.exp(-elapsedMinutes / decayConstantMinutes);
    return math.max(0, base - remaining);
  }

  /// Roadmap section 4.1 + 4.3 — gaana skip hua, uske saare tags ka score
  /// girao. Lagatar `kEscalationThreshold` ya usse zyada baar same tag
  /// skip hua to penalty double (ya jyada) lagti hai.
  void recordSkip(List<String> tags) {
    final now = DateTime.now();
    for (final tag in tags) {
      final consecutive = (_consecutiveSkips[tag] ?? 0) + 1;
      _consecutiveSkips[tag] = consecutive;

      final penalty = consecutive >= kEscalationThreshold
          ? kSkipPenalty * kEscalationMultiplier
          : kSkipPenalty;
      final existing = _activePenalties[tag] ?? 0;
      // If a tag is skipped again before its old penalty has recovered, keep
      // the remaining penalty and add the new event. This makes escalation
      // temporary rather than permanently lowering the base score.
      final last = _lastSkippedAt[tag];
      var remaining = existing;
      if (last != null && existing > 0) {
        final elapsed = now.difference(last).inSeconds / 60.0;
        remaining = existing * math.exp(-elapsed / (kDecayConstant.inSeconds / 60.0));
      }
      _activePenalties[tag] = remaining + penalty;
      _lastSkippedAt[tag] = now;
    }
    notifyListeners();
  }

  /// Roadmap section 4.3 — "Counter reset ho jata hai jaise hi us tag ka
  /// gana poora sun liya ya skip nahi kiya". Poora sun liye gaane ke tags
  /// pe call karo (radio_history me `wasSkipped: false` record karte waqt).
  void recordCompleted(List<String> tags) {
    for (final tag in tags) {
      _consecutiveSkips[tag] = 0;
    }
  }

  /// Roadmap section 10 — favorite/like se us mood ka score positive boost
  /// (skip-penalty ka opposite), taaki similar-mood gaane thode zyada aayein.
  void recordFavorite(List<String> tags) {
    for (final tag in tags) {
      _favoriteBoostCounts[tag] = (_favoriteBoostCounts[tag] ?? 0) + 1;
      _baseScores[tag] = _baseScoreFor(tag) + kFavoriteBoost;
      _consecutiveSkips[tag] = 0;
    }
    notifyListeners();
  }

  void removeFavorite(List<String> tags) {
    for (final tag in tags) {
      final count = _favoriteBoostCounts[tag] ?? 0;
      if (count <= 0) continue;
      final next = count - 1;
      if (next == 0) {
        _favoriteBoostCounts.remove(tag);
      } else {
        _favoriteBoostCounts[tag] = next;
      }
      _baseScores[tag] = _baseScoreFor(tag) - kFavoriteBoost;
      if ((_baseScores[tag] ?? kNeutralScore) <= kNeutralScore) {
        _baseScores.remove(tag);
      }
    }
    notifyListeners();
  }

  /// ☰ "Reset & Change Language" (Phase 7 UI isko call karega) — roadmap:
  /// "Radio reset ho jayega, session ka mood data clear ho jayega".
  /// Language selection jaanbujh kar clear NAHI hoti (roadmap section 6:
  /// "pehle se selected languages pre-ticked dikhein") — sirf mood state.
  void resetMoodState() {
    _baseScores.clear();
    _lastSkippedAt.clear();
    _activePenalties.clear();
    _consecutiveSkips.clear();
    _favoriteBoostCounts.clear();
    notifyListeners();
  }

  /// Phase 7 — Reset & Change Language.
  /// Clears only the temporary Radio session mood state; selected languages
  /// intentionally remain persisted so the language screen can pre-tick them.
  void resetRadioSession() {
    resetMoodState();
  }
}
