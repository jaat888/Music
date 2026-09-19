// lib/screens/radio_player_screen.dart
// SurSathi v55 Radio Enhanced — same Radio UI, hardened transition/playback layer.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../services/app_logger.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/lyrics_service.dart';
import '../services/radio_engine.dart';
import '../services/radio_history_store.dart';
import '../services/radio_service.dart';
import '../services/youtube_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/animated_play_button.dart';
import '../widgets/loading_ring.dart';
import '../widgets/radio_swipe_stage.dart';
import 'radio_language_select_screen.dart';

class RadioPlayerScreen extends StatefulWidget {
  final List<String> languages;
  const RadioPlayerScreen({super.key, required this.languages});

  @override
  State<RadioPlayerScreen> createState() => _RadioPlayerScreenState();
}

class _RadioPlayerScreenState extends State<RadioPlayerScreen> {
  final _engine = RadioEngine();
  final _candidates = <RadioCandidate>[];
  final _upcoming = <RadioCandidate>[];
  final _playedStack = <RadioCandidate>[];
  final _artworkCache = <String, NetworkImage>{};

  StreamSubscription<ProcessingState>? _completionSub;
  RadioCandidate? _current;
  bool _loading = true;
  bool _loadingNext = false;
  bool _paused = false;
  bool _liked = false;
  bool _lyricsLoading = false;
  LyricsResult? _lyrics;
  String? _error;
  int _sessionGeneration = 0;
  int _candidateGeneration = 0;
  int _candidateFetchGeneration = 0;
  DateTime? _currentPlaybackStartedAt;
  bool _transitioning = false;
  int? _radioOwnerId;

  // BUG FIX (v80 — user-verified list, #1/#3/#4: "Next/Previous/Play-Pause
  // command transition ke dauraan drop ho jaati hai"): pehle
  // `_transitioning==true` hone par Next/Previous seedha `return` kar
  // dete the, aur Play/Pause button `onTap: null` ho jaata tha — dono
  // cases mein user ka tap/swipe bilkul chup-chaap discard ho jaata tha,
  // koi effect nahi hota tha jab tak transition khud khatam na ho jaaye.
  // Fix: is dauraan aayi command yahan "pending" register hoti hai —
  // transition ke `finally` block ke turant baad (`_drainPendingRadioCommand()`)
  // ye khud-ba-khud apply ho jaati hai. Sirf AAKHRI nav-intent (next ya
  // previous) rakha jaata hai — rapid taps ek hi resolve-chain mein
  // multiple songs skip nahi karenge (jaanbujhkar coalesce, spam-proof).
  String? _pendingNav; // 'next' | 'previous' | null
  bool? _pendingPlayIntent; // true=resume chahiye, false=pause chahiye, null=koi pending intent nahi

  // `RadioSwipeStage` ke andar inner content-crossfade (AnimatedSwitcher)
  // ki direction ke liye — sirf non-drag navigation (auto-advance, media
  // notification ka next/prev, pending-nav drain) ke liye use hota hai;
  // asli drag-swipe ki animation ab poori tarah `RadioSwipeStage` khud
  // sambhalta hai (live finger-follow + peek-preview), niche `build()`
  // dekho. Default true (up) taaki pehla load bhi consistent lage.
  bool _swipedUp = true;
  String? _recoveringSongId;
  Future<bool>? _recoveryFuture;
  int? _recoveringCandidateGeneration;
  final Map<String, int> _recentLanguageCounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    _radioOwnerId = audioHandler.claimRadioPlaybackOwned(
      onNext: () => _advance(auto: false),
      onPrevious: _previous,
      onError: _onRadioPlaybackError,
    );
    _completionSub = audioHandler.player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed || !mounted || _current == null || _transitioning) return;
      final startedAt = _currentPlaybackStartedAt;
      final duration = audioHandler.player.duration;
      final position = audioHandler.player.position;
      final nearEnd = duration == null ||
          duration <= Duration.zero ||
          position >= duration - const Duration(seconds: 2);
      final ownsCompletedSource = startedAt != null && nearEnd;
      if (!ownsCompletedSource) {
        AppLogger.instance.log('[RADIO] completed signal ignored — current candidate ki confirmed playback identity nahi mili; stale completion suspect.');
        return;
      }
      AppLogger.instance.log('[RADIO] current candidate completed after confirmed playback start (${DateTime.now().difference(startedAt!).inMilliseconds}ms).');
      unawaited(_advance(auto: true));
    });
    _start();
  }

  @override
  void dispose() {
    _completionSub?.cancel();
    final ownerId = _radioOwnerId;
    _radioOwnerId = null;
    if (ownerId != null) {
      unawaited(audioHandler.releaseRadioPlaybackOwned(ownerId));
    }
    _evictRadioArtwork();
    super.dispose();
  }

  static const _lastRadioSongKey = 'radio_last_song_v55';

  Future<RadioCandidate?> _loadLastRadioCandidate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastRadioSongKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final songMap = map['song'] as Map<String, dynamic>?;
      final language = map['language'] as String?;
      if (songMap == null || language == null || !widget.languages.contains(language)) {
        return null;
      }
      return RadioCandidate.fromSong(
        Song.fromJson(songMap),
        language: language,
        categoryHint: RadioLanguageSelectLookup.byCode(language)?.categoryHint,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLastRadioCandidate(RadioCandidate candidate) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastRadioSongKey,
        jsonEncode({
          'song': candidate.song.toJson(),
          'language': candidate.language,
        }),
      );
    } catch (_) {}
  }

  Future<void> _start() async {
    final generation = ++_sessionGeneration;
    AppLogger.instance.log('[RADIO] _start() — session #$generation shuru.');
    await RadioHistoryStore.instance.init();
    _engine.clearFailed();
    _candidates.clear();
    _upcoming.clear();
    _playedStack.clear();
    _recentLanguageCounts.clear();
    final liked = await LikeService.instance.getAllLiked();
    _engine.setLikedIds(liked.map((song) => song.id));
    if (!mounted || generation != _sessionGeneration) return;

    setState(() {
      _loading = true;
      _error = null;
      _lyrics = null;
      _lyricsLoading = false;
    });

    try {
      // Re-entering Radio should feel like resuming, not starting from zero.
      // Try the last Radio song first; background_service will use its warm
      // disk/URL cache when available, so the first screen can start without
      // waiting for a fresh candidate search.
      var started = false;
      final last = await _loadLastRadioCandidate();
      if (last != null) {
        AppLogger.instance.log('[RADIO] _start() — last session ka "${last.song.title}" resume try kar rahe hain.');
        _candidates.add(last);
        started = await _playCandidate(last, addToHistory: false);
        if (!mounted || generation != _sessionGeneration) return;
        if (!started) {
          AppLogger.instance.log('[RADIO] _start() — resume fail hua ("${last.song.title}"), fresh candidates dhoondenge.');
          _engine.markFailed(last.song.id);
          _candidates.removeWhere((c) => c.song.id == last.song.id);
        }
      }

      // Search/fill the real Radio pool after the resume attempt.
      await _fetchCandidates();
      if (!mounted || generation != _sessionGeneration) return;
      if (!started) {
        for (var attempt = 0; attempt < 12 && !started; attempt++) {
          final candidate = _pickNext(excludeIds: const <String>{});
          if (candidate == null) break;
          AppLogger.instance.log('[RADIO] _start() — attempt ${attempt + 1}/12: "${candidate.song.title}" try kar rahe hain.');
          started = await _playCandidate(candidate, addToHistory: true);
          // A newer Radio navigation invalidates this startup session.
          // Do NOT continue the startup retry loop or it will replace the
          // song selected by the user and produce multiple apparent skips.
          if (!mounted || generation != _sessionGeneration) return;
          if (!started) _engine.markFailed(candidate.song.id);
        }
      }
      if (!started) throw StateError('No playable radio candidate');
      AppLogger.instance.log('[RADIO] _start() TASK COMPLETE — session #$generation shuru ho gaya.');
      unawaited(_fillUpcoming());
    } catch (e) {
      AppLogger.instance.log('[RADIO] _start() FAILED — koi bhi candidate play nahi ho paya: $e', level: 'ERROR');
      if (!mounted || generation != _sessionGeneration) return;
      setState(() {
        _loading = false;
        _error = 'Radio songs load nahi ho paaye. Internet check karke retry karein.';
      });
    }
  }

  Future<void> _fetchCandidates() async {
    final fetchGeneration = ++_candidateFetchGeneration;
    final sessionGeneration = _sessionGeneration;
    final localCandidates = <RadioCandidate>[];
    final byId = <String, int>{};
    final languages = widget.languages.toSet();
    final targetCandidateCount = (languages.length * 12).clamp(24, 60).toInt();

    int eligibleCount() => _engine
        .buildPool(localCandidates, selectedLanguages: widget.languages)
        .length;

    void addResults(
      Iterable<YtResult> results,
      String language,
      RadioLanguageSelectLookup option,
      int queryIndex,
    ) {
      var rank = 0;
      for (final item in results) {
        final rankSignal = (1.0 - (rank / 30.0)).clamp(0.0, 1.0).toDouble();
        rank++;
        final candidate = RadioCandidate.fromSong(
          item.toSong(),
          language: language,
          categoryHint: option.categoryHint,
          popularity: queryIndex == 0 ? rankSignal : rankSignal * 0.35,
          recency: queryIndex == 1 ? (0.30 + rankSignal * 0.50) : 0.12,
          isLatest: queryIndex == 1,
        );
        final existingIndex = byId[item.id];
        if (existingIndex == null) {
          byId[item.id] = localCandidates.length;
          localCandidates.add(candidate);
        } else {
          final existing = localCandidates[existingIndex];
          localCandidates[existingIndex] = existing.copyWith(
            popularity: existing.popularity > candidate.popularity ? existing.popularity : candidate.popularity,
            recency: existing.recency > candidate.recency ? existing.recency : candidate.recency,
            isLatest: existing.isLatest || candidate.isLatest,
          );
        }
      }
    }

    final queryList = <({String language, RadioLanguageSelectLookup option, String query, int index})>[];
    for (final language in languages) {
      final option = RadioLanguageSelectLookup.byCode(language);
      if (option == null) continue;
      queryList.add((language: language, option: option, query: option.hitsQuery, index: 0));
      queryList.add((language: language, option: option, query: option.latestQuery, index: 1));
    }

    // Pass 1: fast YT Music search. This preserves the curated first-page
    // ranking users normally expect from Radio.
    for (final item in queryList) {
      try {
        final results = await YoutubeService.instance.search(
          item.query,
          max: 30,
          dateFilter: item.index == 1 ? YtDateFilter.month : YtDateFilter.relevance,
        );
        if (!mounted ||
            sessionGeneration != _sessionGeneration ||
            fetchGeneration != _candidateFetchGeneration) return;
        addResults(results, item.language, item.option, item.index);
      } catch (_) {}
    }

    // Pass 2: when the hard-history/failed/duplicate filters have eaten much
    // of the first page, walk real InnerTube continuations to obtain fresh
    // candidate material instead of repeatedly searching the same page.
    if (eligibleCount() < targetCandidateCount) {
      for (final item in queryList) {
        if (eligibleCount() >= targetCandidateCount) break;
        try {
          var page = await YoutubeService.instance.searchPage(item.query);
          if (!mounted ||
              sessionGeneration != _sessionGeneration ||
              fetchGeneration != _candidateFetchGeneration) return;
          // The first page normally overlaps the fast search above; consume it
          // only for dedupe/metadata merge, then follow its continuation.
          addResults(page.items, item.language, item.option, item.index);
          var pageCount = 0;
          while (page.continuation != null &&
              pageCount < 2 &&
              eligibleCount() < targetCandidateCount) {
            page = await YoutubeService.instance.searchPage(
              item.query,
              continuation: page.continuation,
            );
            if (!mounted ||
                sessionGeneration != _sessionGeneration ||
                fetchGeneration != _candidateFetchGeneration) return;
            addResults(page.items, item.language, item.option, item.index);
            pageCount++;
          }
        } catch (_) {}
      }
    }

    if (!mounted ||
        sessionGeneration != _sessionGeneration ||
        fetchGeneration != _candidateFetchGeneration) return;
    if (localCandidates.isEmpty) throw StateError('No radio candidates');
    _candidates
      ..clear()
      ..addAll(localCandidates);
  }

  Map<String, int> _recentArtistCountsForRanking({int window = 8}) {
    // Persisted 45-minute history is the short-term memory; merge the
    // in-memory session tail so just-played artists are counted immediately
    // even while the async history write is still pending.
    final sessionCandidates = [
      ...(_playedStack.length > window
          ? _playedStack.sublist(_playedStack.length - window)
          : _playedStack),
      if (_current != null) _current!,
    ];
    final sessionSongIds = sessionCandidates.map((c) => c.song.id).toSet();
    final out = <String, int>{
      ...RadioHistoryStore.instance.recentArtistCounts(
        within: const Duration(minutes: 45),
        excludeSongIds: sessionSongIds,
      ),
    };
    final start = _playedStack.length > window
        ? _playedStack.length - window
        : 0;
    for (final candidate in _playedStack.sublist(start)) {
      final artist = candidate.song.artist.trim().toLowerCase();
      if (artist.isEmpty) continue;
      out[artist] = (out[artist] ?? 0) + 1;
    }
    final current = _current;
    if (current != null) {
      final artist = current.song.artist.trim().toLowerCase();
      if (artist.isNotEmpty) out[artist] = (out[artist] ?? 0) + 1;
    }
    return out;
  }

  Map<String, int> _recentTagCountsForRanking({int window = 8}) {
    final out = <String, int>{};
    final start = _playedStack.length > window
        ? _playedStack.length - window
        : 0;
    for (final candidate in _playedStack.sublist(start)) {
      for (final tag in candidate.tags) {
        out[tag] = (out[tag] ?? 0) + 1;
      }
    }
    final current = _current;
    if (current != null) {
      for (final tag in current.tags) {
        out[tag] = (out[tag] ?? 0) + 1;
      }
    }
    return out;
  }

  RadioCandidate? _pickNext({Set<String> excludeIds = const <String>{}}) {
    return _engine.pickNext(
      _candidates,
      selectedLanguages: widget.languages,
      excludeIds: excludeIds,
      recentLanguageCounts: _recentLanguageCounts,
      recentArtistCounts: _recentArtistCountsForRanking(),
      recentTagCounts: _recentTagCountsForRanking(),
    );
  }

  Future<bool> _playCandidate(
    RadioCandidate candidate, {
    required bool addToHistory,
  }) async {
    final token = ++_candidateGeneration;

    // Commit all visible Radio identity fields together before playback begins.
    // The background handler commits the media notification at the same point.
    _current = candidate;
    _paused = false;
    _lyrics = null;
    _lyricsLoading = true;
    // BUG FIX (2026-09-17, v68 — user: "next/prev button se karta hoon to
    // instant nahi hai"): pehle yahan `await LikeService.instance.
    // isLiked(...)` tha — ek DB read jo playback resolution shuru hone se
    // PEHLE hi block karta tha. Heart-icon status playback ke liye zaroori
    // nahi hai — ab parallel/non-blocking hai, resolution turant shuru
    // hota hai.
    unawaited(LikeService.instance.isLiked(candidate.song.id).then((liked) {
      if (!mounted || token != _candidateGeneration) return;
      _engine.setLiked(candidate.song.id, liked);
      setState(() => _liked = liked);
    }));
    if (!mounted || token != _candidateGeneration) return false;

    unawaited(_saveLastRadioCandidate(candidate));

    setState(() {
      _loading = true;
    });
    unawaited(_preloadArtworkAndMetadata());

    final started = await _playWithRecovery(candidate, token);
    if (!mounted || token != _candidateGeneration) return false;
    if (started) _currentPlaybackStartedAt = DateTime.now();

    if (!started) {
      _engine.markFailed(candidate.song.id);
      _upcoming.removeWhere((item) => item.song.id == candidate.song.id);
      _lyrics = null;
      _lyricsLoading = false;
      // BUG FIX (2026-09-17, v68 — user report: "play/pause button ghumta
      // hi rehta hai"): ROOT CAUSE mila — `_loading` upar `true` set hota
      // hai (line ~258), lekin is FAILURE branch mein kabhi wapas `false`
      // nahi hota tha. `_previous()` sirf EK hi `_playCandidate()` call
      // karta hai (koi retry-loop nahi) — agar wahi ek candidate fail ho
      // jaaye (network hiccup, dead video, etc.), `_loading` hamesha ke
      // liye `true` atka reh jaata — play/pause button (jo `_loading ||
      // _transitioning || ...` dekh ke spinner dikhata hai) permanently
      // ghumta reh jaata, chahe player actually kuch bhi na kar raha ho.
      if (mounted) setState(() => _loading = false);
      return false;
    }

    _recentLanguageCounts[candidate.language.toLowerCase()] =
        (_recentLanguageCounts[candidate.language.toLowerCase()] ?? 0) + 1;
    _engine.markPlayed(candidate.song.id);
    setState(() => _loading = false);

    if (addToHistory) {
      // BUG FIX (2026-09-17, v68): pehle ye `await` hota tha — matlab
      // `_playCandidate()` ka Future tab tak complete NAHI hota tha jab
      // tak ye DB write poora na ho jaaye. `_advance()`/`_previous()` ka
      // `_transitioning=false` (jo Next/Prev button ka spinner control
      // karta hai) `finally` block mein hai, jo sirf tab chalta hai jab
      // poora `_advance()`/`_previous()` Future resolve ho — matlab AUDIO
      // already baj raha hota (kyunki `_loading=false` upar hi ho chuka
      // hai), lekin button abhi bhi "loading" dikhata rehta jab tak ye
      // history-log DB write (jo user ko kuch dikhta bhi nahi) khatam na
      // ho jaaye. Fire-and-forget — history save hoti rahegi, bas ab
      // button ko block nahi karti.
      unawaited(RadioHistoryStore.instance.record(
        songId: candidate.song.id,
        title: candidate.song.title,
        tags: candidate.tags,
        language: candidate.language,
        artist: candidate.song.artist,
        duration: candidate.song.duration,
        wasSkipped: false,
      ));
    }

    unawaited(_loadLyrics(candidate, token));
    // Fill Radio's look-ahead only after the current candidate has
    // committed successfully. `_fillUpcoming()` owns the single Radio
    // preload pass, so we intentionally do NOT issue a second prefetch here.
    // Keeping one owner avoids the old v108 mismatch where this path warmed
    // 2 songs while `_preloadArtworkAndMetadata()` warmed 3.
    unawaited(_fillUpcoming());
    return true;
  }

  Future<bool> _playWithRecovery(RadioCandidate candidate, int token) async {
    if (!mounted || token != _candidateGeneration) return false;
    try {
      await audioHandler.playWithRetry(candidate.song);
    } catch (_) {}

    if (!mounted || token != _candidateGeneration) return false;

    // v106 (v84 ka follow-up): playWithRetry() just_audio ke `playing=true`
    // publish karne se kuch ms pehle return kar sakta hai, aur ExoPlayer
    // hand-off ke dauraan `player.playing` chhoti si der `false` bhi ho
    // sakta hai. Raw `player.playing` / `playingStream.first` par tikne se
    // ek valid start "failed candidate" ban jaata tha. Ab wahi effective
    // signal jo UI/notification use karte hain: `playbackStarted` latch +
    // position-advance fallback (dekho `waitForEffectiveStart`).
    if (audioHandler.playbackStarted) return true;
    final started = await audioHandler.waitForEffectiveStart(
      timeout: const Duration(seconds: 6),
    );
    if (!mounted || token != _candidateGeneration) return false;
    if (started) return true;
    return _ensureRecovery(candidate, token, autoAdvanceOnFailure: false);
  }

  Future<void> _onRadioPlaybackError(Song song) async {
    AppLogger.instance.log('[RADIO] _onRadioPlaybackError("${song.title}") called — background_service se error mila.');
    if (!mounted || _current?.song.id != song.id) return;
    final token = _candidateGeneration;
    final candidate = _current!;
    final recovered = await _ensureRecovery(
      candidate,
      token,
      autoAdvanceOnFailure: true,
    );
    AppLogger.instance.log('[RADIO] _onRadioPlaybackError("${song.title}") — recovered=$recovered.');
    if (!recovered && mounted && _current?.song.id == song.id) {
      // _ensureRecovery owns the final failure state and has already skipped
      // the failed candidate when this callback is the background path.
      return;
    }
  }

  Future<bool> _ensureRecovery(
    RadioCandidate candidate,
    int token, {
    required bool autoAdvanceOnFailure,
  }) async {
    if (_recoveringSongId == candidate.song.id &&
        _recoveringCandidateGeneration == token &&
        _recoveryFuture != null) {
      return _recoveryFuture!;
    }

    final completer = Completer<bool>();
    _recoveringSongId = candidate.song.id;
    _recoveringCandidateGeneration = token;
    _recoveryFuture = completer.future;

    () async {
      var recovered = false;
      try {
        for (var retry = 1; retry <= 8; retry++) {
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted ||
              token != _candidateGeneration ||
              _current?.song.id != candidate.song.id) {
            AppLogger.instance.log('[RADIO] _ensureRecovery("${candidate.song.title}") — beech me hi cancel (naya candidate aa gaya ya screen band ho gayi).');
            break;
          }
          AppLogger.instance.log('[RADIO] _ensureRecovery("${candidate.song.title}") — retry $retry/8 (playWithRetry() call kar rahe hain).');
          try {
            await audioHandler.playWithRetry(candidate.song);
          } catch (_) {}
          // BUG FIX (user report: "Next karo to agla nahi, PICHLA gaana
          // baj jaata hai" jab current gaana stuck/buffering ho): upar
          // wala `await audioHandler.playWithRetry(...)` kaafi der (network
          // resolve) le sakta hai. Agar is AWAIT ke DAURAAN hi user ne
          // khud Next/Previous kar diya, `_candidateGeneration`/`_current`
          // tab tak NAYE gaane pe move ho chuke hote hain — lekin ye
          // OLD candidate ka playWithRetry() call abhi bhi return hone ke
          // baad seedha "recovered=true" maan ke `_loading=false` set kar
          // deta (state confuse ho jaata, aur agar iska apna audio-commit
          // naye wale se REKE aa jaaye to purana/OLD gaana hi sunayi
          // deta — "previous" jaisa lagta hai). Fix: yahan bhi VAHI
          // staleness check jo LOOP ke top pe hai — agar is await ke
          // dauraan naya candidate/generation aa chuka hai, ye result
          // bilkul discard karo, kuch mat badlo (naya candidate ka apna
          // playWithRetry() already chal/chuk raha hoga, use hi jeetne do).
          if (!mounted ||
              token != _candidateGeneration ||
              _current?.song.id != candidate.song.id) {
            AppLogger.instance.log(
              '[RADIO] _ensureRecovery("${candidate.song.title}") — playWithRetry() ke AWAIT ke dauraan hi stale ho gaya (user aage badh chuka), result discard.',
            );
            break;
          }
          // v106: raw `player.playing` / `playingStream.first` ki jagah wahi
          // effective start signal (latch + position-advance) — dekho
          // `_playWithRecovery` ka comment. Wait ke DAURAAN user aage badh
          // gaya ho to result discard (upar wala staleness-check yahan bhi).
          final started = audioHandler.playbackStarted ||
              await audioHandler.waitForEffectiveStart(
                timeout: const Duration(seconds: 6),
              );
          if (!mounted ||
              token != _candidateGeneration ||
              _current?.song.id != candidate.song.id) {
            AppLogger.instance.log(
              '[RADIO] _ensureRecovery("${candidate.song.title}") — start-wait ke dauraan hi stale ho gaya, result discard.',
            );
            break;
          }
          recovered = started;
          if (recovered) {
            AppLogger.instance.log('[RADIO] _ensureRecovery("${candidate.song.title}") TASK COMPLETE — retry $retry pe recover ho gaya.');
            if (mounted) setState(() => _loading = false);
            break;
          }
        }

        if (!recovered && mounted && _current?.song.id == candidate.song.id) {
          AppLogger.instance.log('[RADIO] _ensureRecovery("${candidate.song.title}") FAILED — 8 retries ke baad bhi nahi bajaya, agle candidate pe jaa rahe hain.', level: 'ERROR');
          _engine.markFailed(candidate.song.id);
          _upcoming.removeWhere((item) => item.song.id == candidate.song.id);
          if (autoAdvanceOnFailure) {
            await _advance(auto: true, failedSongId: candidate.song.id);
          }
        }
      } finally {
        if (!completer.isCompleted) completer.complete(recovered);
        if (_recoveringSongId == candidate.song.id &&
            _recoveringCandidateGeneration == token) {
          _recoveringSongId = null;
          _recoveringCandidateGeneration = null;
          _recoveryFuture = null;
        }
      }
    }();

    return completer.future;
  }

  Future<void> _loadLyrics(RadioCandidate candidate, int token) async {
    try {
      final result = await LyricsService.instance.getForSong(
        songId: candidate.song.id,
        title: candidate.song.title,
        artist: candidate.song.artist,
        durationSeconds: candidate.song.duration,
      );
      if (!mounted ||
          token != _candidateGeneration ||
          _current?.song.id != candidate.song.id) {
        return;
      }
      setState(() {
        _lyrics = result;
        _lyricsLoading = false;
      });
    } catch (_) {
      if (mounted &&
          token == _candidateGeneration &&
          _current?.song.id == candidate.song.id) {
        setState(() {
          _lyrics = const LyricsResult();
          _lyricsLoading = false;
        });
      }
    }
  }

  Future<void> _preloadArtworkAndMetadata() async {
    final gen = _candidateGeneration;
    final songs = <Song>[];
    if (_current != null) songs.add(_current!.song);
    songs.addAll(_upcoming.map((c) => c.song));
    final next = songs.take(10).toList();

    for (final song in next) {
      if (song.thumb.isEmpty) continue;
      final provider = _artworkCache.putIfAbsent(song.id, () => NetworkImage(song.thumb));
      if (!mounted || gen != _candidateGeneration) return;
      try {
        await precacheImage(provider, context);
      } catch (_) {}
    }
    _trimArtworkCache();

    // BUG FIX (Radio "subtitle" stuck-loading / slow skip — v58): tag this
    // prefetch pass with the candidate generation it started for. Once the
    // listener skips past this song, `_candidateGeneration` moves on and
    // this now-stale pass stops instead of continuing to burn bandwidth —
    // and compete with the *new* current song's own lyrics/audio fetch —
    // for songs nobody is listening to anymore.
    if (!mounted || gen != _candidateGeneration) return;
    unawaited(
      LyricsService.instance.prefetchForSongs(
        next,
        maxSongs: 10,
        isCancelled: () => _candidateGeneration != gen,
      ),
    );
    // BUG FIX (v56 — user report: "agle 5 gano ke request pehle se chale
    // jaye, taiyar rahe"): pehle sirf agle 2 hi prefetch hote the (BUG-32
    // ka jaanbujhkar liya gaya conservative default) — teesri baar skip
    // karte hi loading spinner wapas aa jaata tha (screenshot me exactly
    // yahi dikh raha tha). Ab agle 5 songs ke stream URL + disk cache
    // pehle se taiyar rehte hain, isliye kai skips lagatar bhi instant
    // rehte hain.
    // Radio has its own `_upcoming` list; QueueService.upcoming is empty
    // while Radio owns playback. Use the actual Radio look-ahead here so
    // the next songs really get their URL warmed. Full downloads are still
    // NOT started — only the serialized URL warm-up in BackgroundService.
    if (!mounted || gen != _candidateGeneration) return;
    unawaited(audioHandler.prefetchRadioSongs(
      _upcoming.take(3).map((candidate) => candidate.song).toList(),
    ));
  }

  void _trimArtworkCache() {
    while (_artworkCache.length > 12) {
      final id = _artworkCache.keys.first;
      final provider = _artworkCache.remove(id);
      if (provider != null) {
        PaintingBinding.instance.imageCache.evict(provider);
      }
    }
  }

  void _evictRadioArtwork() {
    for (final provider in _artworkCache.values) {
      PaintingBinding.instance.imageCache.evict(provider);
    }
    _artworkCache.clear();
  }

  Future<void> _fillUpcoming() async {
    if (_loadingNext || _candidates.isEmpty) return;
    final sessionGeneration = _sessionGeneration;
    final candidateGeneration = _candidateGeneration;
    _loadingNext = true;
    try {
      List<RadioCandidate> buildFresh() {
        final used = <String>{
          if (_current != null) _current!.song.id,
          ..._upcoming.map((e) => e.song.id),
        };
        final artistCounts = _recentArtistCountsForRanking();
        final tagCounts = _recentTagCountsForRanking();
        final desired = (10 - _upcoming.length).clamp(0, 10).toInt();
        final result = _engine.buildLookAhead(
          _candidates,
          selectedLanguages: widget.languages,
          count: desired,
          excludeIds: used,
          recentLanguageCounts: _recentLanguageCounts,
          recentArtistCounts: artistCounts,
          recentTagCounts: tagCounts,
        );
        return result;
      }

      var fresh = buildFresh();

      // If the current candidate pool cannot fill the look-ahead, refresh the
      // pool before giving up. This is the key guard against long Radio
      // sessions exhausting the initial search batch.
      if (fresh.length < (10 - _upcoming.length) &&
          sessionGeneration == _sessionGeneration &&
          candidateGeneration == _candidateGeneration) {
        try {
          await _fetchCandidates();
        } catch (_) {}
        if (sessionGeneration != _sessionGeneration ||
            candidateGeneration != _candidateGeneration) return;
        fresh = buildFresh();
      }

      if (sessionGeneration != _sessionGeneration ||
          candidateGeneration != _candidateGeneration) return;
      _upcoming.addAll(fresh);
    } finally {
      _loadingNext = false;
    }
    if (!mounted ||
        sessionGeneration != _sessionGeneration ||
        candidateGeneration != _candidateGeneration) return;
    setState(() {});
    unawaited(_preloadArtworkAndMetadata());
  }

  Future<void> _advance({required bool auto, String? failedSongId}) async {
    if (_current == null) return;
    // STABILITY FIX (v89): startup/resume `_start()` can still be awaiting a
    // candidate while the user swipes/taps Next, or a track completes.
    // In that race the old `_start()` used to see its `_playCandidate()` as
    // false (because candidate generation changed) and then continue its
    // own 12-candidate loop, hijacking the newly selected song. Invalidate
    // the startup generation as soon as Radio advances so the old startup
    // loop exits instead of skipping through several songs.
    _sessionGeneration++;
    // BUG FIX (v80, #1 — dekho `_pendingNav` field ka poora comment): pehle
    // yahan `_transitioning` hone par bhi seedha `return` hota tha — command
    // chup-chaap discard. Ab queue kar dete hain, transition khatam hote hi
    // `_drainPendingRadioCommand()` khud isse chala dega.
    if (_transitioning) {
      _pendingNav = 'next';
      AppLogger.instance.log(
        '[RADIO] _advance(auto=$auto) — transition already in-progress, "next" queued for after.',
      );
      return;
    }
    // FIX (user report: "2 number gaane se skip button disable dikhta
    // hai"): pehle `_transitioning = true;` ek plain field-assignment tha,
    // koi setState() nahi tha. Jab transition SHURU hoti thi, jald hi
    // niche `setState(() { _loading = true; })` chalne se button turant
    // disabled dikh jaata tha (uspe koi asar nahi tha). Lekin jab transition
    // KHATAM hoti thi (`finally` block me `_transitioning = false;`), uske
    // BAAD koi setState() nahi hota tha — flag internally false ho jaata
    // (skip technically ready hota), lekin screen kabhi refresh nahi hoti,
    // isliye button HAMESHA disabled/grey hi dikhta reh jaata, jab tak
    // kisi AUR wajah se (jaise heart button dabane se) screen refresh na
    // ho. Ab dono jagah setState() ke andar hain — button turant sahi
    // enable/disable state dikhata hai.
    setState(() => _transitioning = true);
    AppLogger.instance.log(
      '[RADIO] _advance(auto=$auto, failedSongId=$failedSongId) called — current: "${_current!.song.title}"',
    );
    try {
      final old = _current!;
      if (failedSongId == old.song.id) {
        _engine.markFailed(old.song.id);
      } else {
        final seconds = audioHandler.player.position.inSeconds;
        final playerDuration = audioHandler.player.duration?.inSeconds ?? 0;
        final total = playerDuration > 0 ? playerDuration : old.song.duration;
        final ratio = total > 0 ? seconds / total : 0.0;

        // A manual Next very close to the end is treated as a successful
        // listen, not as a negative skip. This prevents Resso-style learning
        // from punishing a song the listener effectively finished.
        final completed = auto || ratio >= .90;
        if (completed) {
          await RadioHistoryStore.instance.markLatestAsCompleted(
            songId: old.song.id,
            listenSeconds: auto ? total : seconds,
            duration: total > 0 ? total : old.song.duration,
          );
          RadioService.instance.recordCompleted(old.tags);
        } else {
          await RadioHistoryStore.instance.markLatestAsSkipped(
            songId: old.song.id,
            skipPositionSec: seconds,
            duration: total > 0 ? total : old.song.duration,
          );
          RadioService.instance.recordSkip(old.tags);
        }
      }

      _playedStack.add(old);
      // BUG FIX (v56 — user report: "gaana khatam hone ke baad apne aap
      // agla gaana nahi chalta"): `_playedStack` kabhi trim nahi hota tha
      // — poori radio session me jitne bhi gaane bajte, sab hamesha ke
      // liye "exclude" list me reh jaate the. Chhoti candidate pool (jaise
      // sirf 1-2 language select kiye ho) ke saath, kaafi der Radio sunne
      // ke baad ye exclude-set poori pool ke barabar ho jaata tha —
      // `_pickNext()` hamesha `null` deta, `_fetchCandidates()` dobara
      // wahi results laata (YouTube search results deterministic hote
      // hain), aur `_advance()` chup-chaap `return` ho jaata — na koi
      // error, na retry, bas agla gaana kabhi shuru hi nahi hota tha.
      // Fix: exclude-set ab sirf RECENT gaano tak limited hai (turant
      // repeat na ho), poori session history tak nahi — pool hamesha
      // recycle ho sakta hai.
      if (_playedStack.length > 60) {
        _playedStack.removeRange(0, _playedStack.length - 60);
      }
      _upcoming.removeWhere((item) => item.song.id == failedSongId);

      List<String> recentExclude([int window = 40]) {
        final recent = _playedStack.length > window
            ? _playedStack.sublist(_playedStack.length - window)
            : _playedStack;
        return recent.map((e) => e.song.id).toList();
      }

      for (var attempt = 0; attempt < 12; attempt++) {
        RadioCandidate? next;
        if (_upcoming.isNotEmpty) {
          next = _upcoming.removeAt(0);
        } else {
          next = _pickNext(
            excludeIds: {old.song.id, ...recentExclude()},
          );
        }
        if (next == null) {
          await _fetchCandidates();
          next = _pickNext(
            excludeIds: {old.song.id, ...recentExclude()},
          );
        }
        // FIX: pool genuinely chhoti ho (thoda languages select kiye ho)
        // to bhi kabhi silently na ruke — exclude window aur chhota
        // karke ek aakhri baar try karo, recent-most repeats ke alawa
        // kuch bhi eligible ho sakta hai.
        if (next == null) {
          next = _pickNext(
            excludeIds: {old.song.id, ...recentExclude(8)},
          );
        }
        if (next == null || !mounted) {
          // Sach mein kuch bhi eligible nahi mila (bahut hi chhoti pool) —
          // ab chup-chaap na ruko, user ko dikhao taaki wo retry kar sake.
          if (mounted) {
            setState(() {
              _loading = false;
              _error = 'Is language selection ke liye naye gaane khatam ho '
                  'gaye. Retry karein ya aur languages select karein.';
            });
          }
          return;
        }

        final ok = await _playCandidate(next, addToHistory: true);
        if (ok) {
          AppLogger.instance.log('[RADIO] _advance() TASK COMPLETE — "${next.song.title}" pe move hua (attempt ${attempt + 1}).');
          return;
        }
        AppLogger.instance.log('[RADIO] _advance() — "${next.song.title}" play nahi hua, agla candidate try karenge (attempt ${attempt + 1}/12).');
        _engine.markFailed(next.song.id);
        _upcoming.removeWhere((item) => item.song.id == next!.song.id);
      }
      // BUG FIX (2026-09-17, v68): 12 attempts ke baad bhi koi candidate
      // play nahi ho paya — pehle yahan loop chup-chaap khatam ho jaata
      // tha, `_loading` (jo har failed `_playCandidate` call ke andar
      // `true` set hua tha) kabhi reset nahi hota — same "button ghumta
      // rehta hai" bug, is baar Next se trigger.
      AppLogger.instance.log('[RADIO] _advance() FAILED — 12 attempts, koi candidate play nahi hua.', level: 'ERROR');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '12 gaane try kiye, koi play nahi ho paya. Retry karein.';
        });
      }
    } finally {
      // FIX: dekho _advance() ke shuru me comment — `finally` yahan bhi
      // pehle bina setState() ke tha, isliye transition khatam hone ke
      // baad bhi button disabled hi dikhta rehta tha.
      if (mounted) setState(() => _transitioning = false);
      // BUG FIX (v80, #1/#3/#4): transition abhi-abhi khatam hui — agar
      // is dauraan koi Next/Previous/Play-Pause command queue hui thi,
      // usse ab apply karo.
      scheduleMicrotask(_drainPendingRadioCommand);
    }
  }

  Future<void> _previous() async {
    _sessionGeneration++;
    if (_transitioning) {
      _pendingNav = 'previous';
      AppLogger.instance.log('[RADIO] _previous() — transition already in-progress, "previous" queued for after.');
      return;
    }
    if (_playedStack.isEmpty) {
      AppLogger.instance.log('[RADIO] _previous() — _playedStack khaali hai, ye pehla gaana hai.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ye is session ka pehla gaana hai'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }

    _candidateGeneration++;
    setState(() => _transitioning = true);
    final current = _current;
    if (current != null) _upcoming.insert(0, current);
    try {
      for (var attempt = 0; attempt < 12 && _playedStack.isNotEmpty; attempt++) {
        final previousCandidate = _playedStack.removeLast();
        AppLogger.instance.log('[RADIO] _previous() attempt ${attempt + 1}/12 — "${previousCandidate.song.title}" try kar rahe hain.');
        final started = await _playCandidate(previousCandidate, addToHistory: false);
        if (started) {
          await RadioHistoryStore.instance.markReplay(previousCandidate.song.id);
          AppLogger.instance.log('[RADIO] _previous() TASK COMPLETE — "${previousCandidate.song.title}" pe move hua; replay signal recorded.');
          return;
        }
        _engine.markFailed(previousCandidate.song.id);
        _upcoming.removeWhere((item) => item.song.id == previousCandidate.song.id);
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Pichhle gaane me se koi play nahi ho paya.';
        });
      }
    } finally {
      if (mounted) setState(() => _transitioning = false);
      scheduleMicrotask(_drainPendingRadioCommand);
    }
  }

  // v106 (v100 ka follow-up): v100 ne raw `player.playing` ki jagah
  // `playbackStarted` liya, lekin icon abhi bhi usse broad signal (`playing ||
  // playbackStarted || (ready && position>250ms)`) se decide hota tha — to
  // hand-off gap mein icon "Pause" dikhta aur yahan `playbackStarted` false
  // milne par tap `play()` ban jaata. Ab icon, onTap AUR yeh function teeno
  // `audioHandler.effectivelyPlaying` (ek hi getter) se chalte hain.
  Future<void> _togglePlay() async {
    final isPlaying = audioHandler.effectivelyPlaying;
    AppLogger.instance.log('[RADIO] _togglePlay() called — effectivelyPlaying=$isPlaying (playbackStarted=${audioHandler.playbackStarted}, raw player.playing=${audioHandler.player.playing})');
    if (isPlaying) {
      await audioHandler.pause();
      if (mounted) setState(() => _paused = true);
    } else {
      await audioHandler.play();
      if (mounted) setState(() => _paused = false);
    }
  }

  // BUG FIX (v80 — dekho `_pendingNav`/`_pendingPlayIntent` field comment
  // upar): har `_advance()`/`_previous()` ke `finally` block ke turant
  // baad call hota hai — us waqt tak `_transitioning` already `false` ho
  // chuka hota hai. Agar is transition ke DAURAAN koi Next/Previous/
  // Play-Pause command aayi thi, wo yahan apply hoti hai.
  //
  // Order: pehle pending NAV (agar hai) — kyunki wahi zyada "current
  // intent" hai (user ne song hi badalna chaha). Agar nav thi to uska
  // apna `_advance()`/`_previous()` call khud apne `finally` ke through
  // isi function ko dobara call karega — is se play-intent bhi us CHAIN
  // ke aakhri transition ke baad hi apply hoga (jaisa hona chahiye —
  // beech wale gaano pe pause lagane ka koi matlab nahi).
  //
  // Agar koi nav pending nahi thi, sirf play/pause intent bacha hai to
  // wahi seedha apply ho jaata hai.
  void _drainPendingRadioCommand() {
    final pendingNav = _pendingNav;
    if (pendingNav != null) {
      _pendingNav = null;
      AppLogger.instance.log('[RADIO] draining pending nav command: $pendingNav');
      if (pendingNav == 'next') {
        unawaited(_advance(auto: false));
      } else {
        unawaited(_previous());
      }
      return;
    }
    final pendingPlay = _pendingPlayIntent;
    if (pendingPlay != null) {
      _pendingPlayIntent = null;
      AppLogger.instance.log('[RADIO] draining pending play-intent: $pendingPlay');
      if (pendingPlay) {
        unawaited(audioHandler.play());
      } else {
        unawaited(audioHandler.pause());
      }
      if (mounted) setState(() => _paused = !pendingPlay);
    }
  }

  Future<void> _confirmResetAndChangeLanguage() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset Radio?'),
        content: const Text(
          'Radio session reset ho jayega aur current mood data clear ho jayega. '
          'Aapki selected languages saved rahengi. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _sessionGeneration++;
    _candidateGeneration++;
    _engine.clearFailed();
    RadioService.instance.resetRadioSession();
    await audioHandler.pause();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RadioLanguageSelectScreen()),
      (route) => route.isFirst,
    );
  }

  Future<void> _toggleLike() async {
    final current = _current;
    if (current == null) return;
    await LikeService.instance.toggleLike(current.song);
    if (!mounted || _current?.song.id != current.song.id) return;
    _liked = await LikeService.instance.isLiked(current.song.id);
    _engine.setLiked(current.song.id, _liked);
    if (_liked) {
      RadioService.instance.recordFavorite(current.tags);
    } else {
      RadioService.instance.removeFavorite(current.tags);
    }
    setState(() {});
  }

  NetworkImage? _artworkFor(RadioCandidate candidate) {
    final url = candidate.song.thumb;
    if (url.isEmpty) return null;
    return _artworkCache.putIfAbsent(candidate.song.id, () => NetworkImage(url));
  }

  // BUG FIX (2026-09-18, v59 — "phone ka back button dabane se Radio/app
  // force-stop jaisa exit ho jaata hai, minimize nahi hota"): is screen pe
  // pehle koi back-button handling hi nahi thi, isliye phone ka hardware/
  // gesture back seedha normal Flutter Navigator pop try karta tha — jab
  // koi aur route pop karne ko na bache, Flutter/Android ka default
  // behavior activity ko `finish()` kar deta hai (background service samet
  // sab kuch achanak tut jaata hai) — normal apps jaisa sirf "minimize"
  // (Home button jaisa, task background me chala jaaye, playback/
  // notification zinda rahe) NAHI hota. Ab yahi phone ka back button sirf
  // poore app ko background me bhej deta hai (MainActivity.kt ka
  // `moveTaskToBack`, dekho waha ka comment) — Radio screen jahan ki wahin
  // rehti hai, gaana bajta rehta hai. Radio se "bahar/exit" (gaana rokna)
  // ab sirf upar wale × button se hi hota hai (`_topBar()` me
  // `Navigator.of(context).pop()`) — us pe koi asar nahi, kyunki
  // `WillPopScope.onWillPop` sirf back-button/system-pop try par hi chalta
  // hai, seedhe `Navigator.pop()` call par nahi.
  static const _navChannel = MethodChannel('com.sursathi.sursathi/nav');

  Future<bool> _onBackPressed() async {
    try {
      await _navChannel.invokeMethod('moveTaskToBack');
    } catch (_) {
      // Channel/native side available na ho (purana build ya kisi wajah
      // se fail) to bhi crash nahi hona chahiye — is case me purana
      // (thoda kharab) default behavior hi chalega, naya jaanbujhke koi
      // aur cheez try nahi karta.
    }
    return false; // Radio screen kabhi back-button se pop/exit nahi hoti.
  }

  // Radio ke `_upcoming`/`_playedStack` mein next/previous candidate ready
  // hote hi (prefetch/artwork-cache samet) rehte hain — `_advance()` khud
  // exactly `_upcoming.first` uthata hai aur `_previous()` exactly
  // `_playedStack.last`, isliye ye "peek" hamesha usi se match karta hai
  // jo drag-commit hone par asal mein bajega.
  RadioCandidate? _peekNext() => _upcoming.isEmpty ? null : _upcoming.first;
  RadioCandidate? _peekPrevious() =>
      _playedStack.isEmpty ? null : _playedStack.last;

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final nextPeek = _peekNext();
    final prevPeek = _peekPrevious();
    return WillPopScope(
      onWillPop: _onBackPressed,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: current == null
            ? _loadingBody()
            // NEW (Reels/Shorts-jaisa live swipe): pehle swipe sirf
            // release pe fire hota tha aur ek chhoti crossfade dikhti
            // thi. Ab `RadioSwipeStage` poori screen ko finger ke saath
            // real-time drag karta hai, aur agla/pichla gaana (jo
            // `_upcoming`/`_playedStack` se pehle se pata hota hai) turant
            // peek ke roop mein slide-in hota hai — asli gaana load hone
            // ka wait nahi karna padta. Seekbar (horizontal-drag) aur
            // buttons (tap) is VERTICAL-only gesture se conflict nahi
            // karte, pehle jaisa hi.
            : RadioSwipeStage(
                contentId: current.song.id,
                canGoNext: nextPeek != null,
                canGoPrevious: prevPeek != null,
                onCommitNext: () {
                  _swipedUp = true;
                  unawaited(_advance(auto: false)); // swipe up → next
                },
                onCommitPrevious: () {
                  _swipedUp = false;
                  unawaited(_previous()); // swipe down → previous
                },
                current: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildArtwork(current),
                    Container(color: Colors.black.withOpacity(.55)),
                    SafeArea(
                      child: _buildContent(current),
                    ),
                  ],
                ),
                peekNext: nextPeek == null ? null : _buildPeekPage(nextPeek),
                peekPrevious:
                    prevPeek == null ? null : _buildPeekPage(prevPeek),
              ),
      ),
    );
  }

  // Halka preview-page — sirf artwork + title/artist/language, koi
  // controls/timeline/lyrics nahi (wo sirf asli "current" candidate ke
  // saath judi hoti hain: buffering-text, seekbar position, waghera). Ye
  // sirf drag ke dauraan, ya commit ke baad asli switch hone tak, dikhta
  // hai — halka spinner reassure karta hai ki agla gaana load ho raha hai.
  Widget _buildPeekPage(RadioCandidate candidate) {
    final provider = _artworkFor(candidate);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (provider != null)
          Image(
            image: provider,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          )
        else
          Container(color: const Color(0xFF141414)),
        Container(color: Colors.black.withOpacity(.55)),
        SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.language.toUpperCase(),
                    style: AppText.bodyS(color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    candidate.song.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.displayL(color: Colors.white),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    candidate.song.artist,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyM(color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArtwork(RadioCandidate current) {
    final provider = _artworkFor(current);
    if (provider == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previousChildren, if (currentChild != null) currentChild],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: Image(
        key: ValueKey(current.song.id),
        image: provider,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildContent(RadioCandidate current) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 680;
        final lyricHeight = compact ? 132.0 : 176.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(20, compact ? 2 : 8, 20, 6),
          child: Column(
            children: [
              // FIX: swipe-gesture ab poore screen (upar build() me) pe
              // hai — yahan sirf plain layout hai, koi alag GestureDetector
              // nahi (pehle yahan ek dusra tha jo sirf isi Expanded tak
              // limited tha, ab hata diya gaya hai).
              Expanded(
                child: Column(
                  children: [
                    SizedBox(height: 48, child: _topBar()),
                    SizedBox(height: compact ? 14 : 24),
                    Expanded(
                      child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) {
                            // Ye sirf NON-drag navigation (auto-advance,
                            // notification next/prev, pending-nav drain)
                            // ke liye chalta hai — asli finger-drag swipe
                            // ki animation `RadioSwipeStage` khud karta
                            // hai (poori screen ke saath, live).
                            final offsetAnim = Tween<Offset>(
                              begin: Offset(0, _swipedUp ? 0.18 : -0.18),
                              end: Offset.zero,
                            ).animate(animation);
                            final scaleAnim = Tween<double>(
                              begin: 0.94,
                              end: 1.0,
                            ).animate(CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutCubic,
                            ));
                            return ClipRect(
                              child: SlideTransition(
                                position: offsetAnim,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: scaleAnim,
                                    child: child,
                                  ),
                                ),
                              ),
                            );
                          },
                          child: Column(
                            key: ValueKey('content-${current.song.id}'),
                            children: [
                              Text(current.language.toUpperCase(), style: AppText.bodyS(color: Colors.white70)),
                              const SizedBox(height: 6),
                              Text(
                                current.song.title,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.displayL(color: Colors.white),
                              ),
                              const SizedBox(height: 5),
                              ValueListenableBuilder<PlaybackPhase>(
                                valueListenable: audioHandler.phase,
                                builder: (context, phase, _) {
                                  String subtitle = current.song.artist;
                                  if (phase != PlaybackPhase.playing &&
                                      phase != PlaybackPhase.paused &&
                                      phase != PlaybackPhase.idle) {
                                    subtitle = audioHandler.phaseMessage.value ??
                                        switch (phase) {
                                          PlaybackPhase.resolving => 'Resolving...',
                                          PlaybackPhase.verifying => 'Verifying...',
                                          PlaybackPhase.buffering => 'Buffering...',
                                          PlaybackPhase.retrying => 'Retrying...',
                                          PlaybackPhase.error => 'Playback error',
                                          _ => subtitle,
                                        };
                                  }
                                  return Text(
                                    subtitle,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.bodyM(color: Colors.white70),
                                  );
                                },
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: Center(
                                  child: SizedBox(
                                    height: lyricHeight,
                                    width: double.infinity,
                                    child: IgnorePointer(
                                      child: RadioLyrics(
                                        key: ValueKey('lyrics-${current.song.id}'),
                                        result: _lyrics,
                                        loading: _lyricsLoading,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ),
                  ],
                ),
              ),
              // Timeline is deliberately the last content block so its
              // position never jumps when lyrics arrive.
              RadioPlayerProgress(
                key: ValueKey('progress-${current.song.id}'),
                player: audioHandler.player,
                isEffectivelyPlaying: () => audioHandler.effectivelyPlaying,
                // Player state is authoritative. Once the new source is
                // READY, the seekbar should become usable even if a small
                // Radio bookkeeping/transition task is still unwinding.
                enabled: audioHandler.player.duration != null &&
                    (audioHandler.player.playing ||
                        audioHandler.player.processingState == ProcessingState.ready),
              ),
              const SizedBox(height: 4),
              _controls(),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: 'Close',
            color: Colors.white,
            iconSize: 22,
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        const Spacer(),
        Text('RADIO', style: AppText.titleM(color: Colors.white)),
        const Spacer(),
        SizedBox(
          width: 48,
          height: 48,
          child: PopupMenuButton<String>(
            tooltip: 'Radio menu',
            icon: const Icon(Icons.menu, color: Colors.white),
            onSelected: (value) {
              if (value == 'reset') unawaited(_confirmResetAndChangeLanguage());
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'reset',
                child: Text('Reset & Change Language'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Navigation is swipe-only in Radio: swipe UP for next and DOWN for
        // previous. No skip icon is shown here.
        StreamBuilder<bool>(
          stream: audioHandler.player.playingStream,
          initialData: audioHandler.player.playing,
          builder: (_, playingTick) {
            return StreamBuilder<Duration>(
              stream: audioHandler.player.positionStream,
              initialData: audioHandler.player.position,
              builder: (_, positionTick) {
                // v106: icon, onTap aur `_togglePlay()` ka EK hi signal.
                // (StreamBuilders sirf rebuild trigger karte hain.)
                final processing = audioHandler.player.processingState;
                final playing = audioHandler.effectivelyPlaying;
                final resolving = !playing &&
                    (_loading ||
                        _transitioning ||
                        processing == ProcessingState.loading ||
                        processing == ProcessingState.buffering);

                return Semantics(
                  button: true,
                  label: resolving ? 'Buffering' : (playing ? 'Pause' : 'Play'),
                  // BUG FIX (user: "normal mode wala hi animation is button
                  // pe bhi laga do"): Radio ka button pehle apna alag
                  // hand-rolled AnimatedContainer+icon-swap tha (jismein
                  // pichle 2 patches mein dikkatein aayi — scale-stuck,
                  // etc.). Ab EXACTLY wahi widgets use kar rahe hain jo
                  // full player ("normal mode") ka MAIN play/pause button
                  // use karta hai — `LoadingRing` (ghumta hua ring +
                  // loading ke dauraan taps absorb) ke andar
                  // `AnimatedPlayButton` (tap-bounce + playing-pulse,
                  // koi icon-swap animation nahi — seedha Icon badalta
                  // hai, isliye pichli "icon invisible ho gaya" jaisi
                  // dikkat yahan structurally ho hi nahi sakti). Ek hi
                  // shared component — dono jagah hamesha same behave
                  // karenge, alag se maintain nahi karna padega.
                  child: LoadingRing(
                    isLoading: resolving,
                    size: 72,
                    child: AnimatedPlayButton(
                      isPlaying: playing,
                      size: 72,
                      onTap: () {
                        // Live read (build-time snapshot nahi) — _togglePlay()
                        // bhi isi getter ko padhta hai.
                        if (audioHandler.effectivelyPlaying) {
                          unawaited(_togglePlay());
                          return;
                        }
                        if (_transitioning || _loading) {
                          setState(() => _pendingPlayIntent = true);
                          AppLogger.instance.log(
                            '[RADIO] Play/Pause tapped during transition/loading — queued: play',
                          );
                          return;
                        }
                        unawaited(_togglePlay());
                      },
                    ),
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(width: 14),
        IconButton(
          tooltip: 'Favorite',
          iconSize: 32,
          color: _liked ? kGreen : Colors.white,
          onPressed: _toggleLike,
          icon: Icon(_liked ? Icons.favorite : Icons.favorite_border),
        ),
      ],
    );
  }

  Widget _loadingBody() {
    return SafeArea(
      child: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, color: Colors.white70, size: 44),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
      ),
    );
  }
}

class RadioPlayerProgress extends StatefulWidget {
  final AudioPlayer player;
  // BUG FIX (seekbar-loading-guard): Next/Prev button ka existing
  // `_transitioning`/loading guard yahan bhi — jab tak naya gaana
  // resolve/ready na ho jaaye, seekbar drag/tap ignore karta hai (warna
  // ek gaana chalte transition ke beech-me hi purani position pe seek()
  // call ho sakta tha, jo either kaam nahi karta ya galat gaane pe seek
  // kar deta).
  final bool enabled;
  final bool Function()? isEffectivelyPlaying;
  const RadioPlayerProgress({
    super.key,
    required this.player,
    this.enabled = true,
    this.isEffectivelyPlaying,
  });

  @override
  State<RadioPlayerProgress> createState() => _RadioPlayerProgressState();
}

class _RadioPlayerProgressState extends State<RadioPlayerProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  bool _dragging = false;
  double _dragMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onFrame)..repeat();
    // just_audio is the authority. Stream events update the slider
    // immediately; the frame ticker only fills the visual gap while playing.
    _positionSub = widget.player.positionStream.listen((_) {
      if (mounted && !_dragging) setState(() {});
    });
    _durationSub = widget.player.durationStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _ticker
      ..removeListener(_onFrame)
      ..dispose();
    super.dispose();
  }

  void _onFrame() {
    if (!mounted || _dragging || !(widget.isEffectivelyPlaying?.call() ?? widget.player.playing)) return;
    setState(() {});
  }

  String _format(Duration d) {
    final totalSeconds = d.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.player.duration ?? Duration.zero;
    final position = _dragging
        ? Duration(milliseconds: _dragMs.round())
        : widget.player.position;
    final maxMs = mathMax(1, duration.inMilliseconds);
    final valueMs = position.inMilliseconds.clamp(0, maxMs).toDouble();
    // Player abhi naya URL resolve/load kar raha ho (buffering ka blip
    // playing ke dauraan ignore — mini_player.dart ka wahi glitch-fix
    // pattern), YA parent screen transition/loading me ho, dono cases me
    // seekbar disabled.
    final playerLoading = widget.player.processingState ==
            ProcessingState.loading ||
        (widget.player.processingState == ProcessingState.buffering &&
            !widget.player.playing);
    final interactive = widget.enabled && !playerLoading;

    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(_format(position), style: AppText.bodyS(color: Colors.white70)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              activeTrackColor: interactive ? kGreen : Colors.white24,
              thumbColor: interactive ? kGreen : Colors.white38,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              min: 0,
              max: maxMs.toDouble(),
              value: valueMs,
              onChangeStart: !interactive
                  ? null
                  : (value) {
                      setState(() {
                        _dragging = true;
                        _dragMs = value;
                      });
                    },
              onChanged: !interactive
                  ? null
                  : (value) {
                      setState(() => _dragMs = value);
                    },
              onChangeEnd: !interactive
                  ? null
                  : (value) async {
                      setState(() {
                        _dragging = false;
                        _dragMs = value;
                      });
                      await widget.player
                          .seek(Duration(milliseconds: value.round()));
                    },
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(_format(duration), textAlign: TextAlign.right, style: AppText.bodyS(color: Colors.white70)),
        ),
      ],
    );
  }

  double mathMax(num a, num b) => a > b ? a.toDouble() : b.toDouble();
}

class RadioLyrics extends StatefulWidget {
  final LyricsResult? result;
  final bool loading;
  const RadioLyrics({super.key, required this.result, required this.loading});

  @override
  State<RadioLyrics> createState() => _RadioLyricsState();
}

class _RadioLyricsState extends State<RadioLyrics> {
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<Duration>? _positionSub;
  int _activeIndex = -1;
  List<LyricLine> _lines = const [];

  @override
  void initState() {
    super.initState();
    _lines = widget.result?.synced ?? const [];
    // FIX (user report: "Radio ki lyrics normal player se lag/late lagti
    // hain"): pehle ek 1-second wala repeating `AnimationController`
    // (`_ticker`) tha jo sirf HAR SECOND ek baar check karta tha "abhi
    // konsi line active honi chahiye" — matlab agli line kabhi 1 second
    // tak DER se highlight hoti thi. Normal (Radio ke bahar wali)
    // `lyrics_screen.dart` seedha player ke `positionStream` pe react
    // karti hai — har position-update pe TURANT. Ab yahan bhi wahi tarika
    // hai, isliye Radio ki lyrics ab utni hi turant/smooth sync hoti hain
    // jitni normal player me hoti hain.
    _positionSub = audioHandler.player.positionStream.listen(_syncActiveLine);
  }

  @override
  void didUpdateWidget(covariant RadioLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newLines = widget.result?.synced ?? const <LyricLine>[];
    if (!identical(newLines, _lines)) {
      _lines = newLines;
      _activeIndex = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lines.isNotEmpty && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  int _findActive(Duration position) {
    var index = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _syncActiveLine(Duration pos) {
    if (!mounted || _lines.isEmpty) return;
    final next = _findActive(pos);
    if (next == _activeIndex) return;
    setState(() => _activeIndex = next);
    // NEW (2026-09-18 — user report: "subtitle screen pe kab aaya, exact
    // time ke saath log ho"): Radio ke synced lyrics me bhi wahi
    // per-line-change log, lyrics_screen.dart jaisa hi.
    if (next >= 0 && next < _lines.length) {
      final mm = pos.inMinutes.remainder(60).toString().padLeft(2, '0');
      final ss = pos.inSeconds.remainder(60).toString().padLeft(2, '0');
      final ms = pos.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
      AppLogger.instance.log(
        '[LYRICS] (radio) line #$next active at $mm:$ss.$ms — "${_lines[next].text}"',
      );
    }
    _centerActive(next);
  }

  void _centerActive(int index) {
    if (index < 0 || !_scrollController.hasClients) return;
    const itemExtent = 56.0;
    const viewportHeight = 165.0;
    final target = (index * itemExtent) - (viewportHeight / 2) + (itemExtent / 2);
    final maxScroll = _scrollController.position.maxScrollExtent;
    final clamped = target.clamp(0.0, maxScroll).toDouble();
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const SizedBox(
        height: 176,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }

    if (_lines.isNotEmpty) {
      return SizedBox(
        height: 176,
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, .16, .84, 1],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: _scrollController,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 60),
            itemExtent: 56,
            itemCount: _lines.length,
            itemBuilder: (_, index) {
              final active = index == _activeIndex;
              return Center(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  style: AppText.bodyM(color: active ? Colors.white : Colors.white54).copyWith(
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    fontSize: active ? 17 : 13,
                    height: 1.18,
                    shadows: active
                        ? const [
                            Shadow(color: Colors.white70, blurRadius: 12),
                            Shadow(color: Colors.white30, blurRadius: 3),
                          ]
                        : const [],
                  ),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: active ? 1 : 0.38,
                    child: Transform.scale(
                      scale: active ? 1 : 0.90,
                      child: Text(
                        _lines[index].text,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }

    final plain = widget.result?.plain?.trim();
    if (plain != null && plain.isNotEmpty) {
      return SizedBox(
        height: 176,
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, .14, .86, 1],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
            physics: const BouncingScrollPhysics(),
            children: [
              Text(
                plain,
                textAlign: TextAlign.center,
                style: AppText.bodyM(color: Colors.white70).copyWith(height: 1.55),
              ),
              const SizedBox(height: 10),
              Text(
                'Lyrics available • sync not available for this version',
                textAlign: TextAlign.center,
                style: AppText.bodyS(color: Colors.white38),
              ),
            ],
          ),
        ),
      );
    }

    return const SizedBox(
      height: 176,
      child: Center(
        child: Text(
          'Lyrics not available for this song',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 14),
        ),
      ),
    );
  }
}

class RadioLanguageSelectLookup {
  final String code;
  final String hitsQuery;
  final String latestQuery;
  final String categoryHint;
  const RadioLanguageSelectLookup(this.code, this.hitsQuery, this.latestQuery, this.categoryHint);

  static const all = <RadioLanguageSelectLookup>[
    RadioLanguageSelectLookup('bollywood', 'bollywood hits songs', 'latest bollywood songs', 'Bollywood'),
    RadioLanguageSelectLookup('punjabi', 'punjabi hits songs', 'latest punjabi songs', 'Punjabi'),
    RadioLanguageSelectLookup('haryanvi', 'haryanvi hits songs', 'latest haryanvi songs', 'Haryanvi'),
  ];

  static RadioLanguageSelectLookup? byCode(String code) {
    for (final item in all) {
      if (item.code == code) return item;
    }
    return null;
  }
}
