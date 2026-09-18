// lib/screens/radio_player_screen.dart
// SurSathi v55 Radio Enhanced — same Radio UI, hardened transition/playback layer.

import 'dart:async';
import 'dart:convert';

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
  bool _transitioning = false;
  // Reels-jaisa swipe animation ke liye — kis taraf se swipe hua, taaki
  // naya content sahi direction se slide-in ho (up-swipe → neeche se aaye,
  // down-swipe → upar se aaye). Default true (up) taaki pehla load bhi
  // consistent lage.
  bool _swipedUp = true;
  String? _recoveringSongId;
  Future<bool>? _recoveryFuture;
  final Map<String, int> _recentLanguageCounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    audioHandler.setRadioPlaybackOwned(
      true,
      onNext: () => _advance(auto: false),
      onPrevious: _previous,
      onError: _onRadioPlaybackError,
    );
    _completionSub = audioHandler.player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed &&
          mounted &&
          _current != null &&
          !_transitioning) {
        unawaited(_advance(auto: true));
      }
    });
    _start();
  }

  @override
  void dispose() {
    _completionSub?.cancel();
    audioHandler.setRadioPlaybackOwned(false);
    unawaited(audioHandler.stop());
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
    _candidates.clear();
    final byId = <String, int>{};
    final languages = widget.languages.toSet();

    for (final language in languages) {
      final option = RadioLanguageSelectLookup.byCode(language);
      if (option == null) continue;
      final queries = [option.hitsQuery, option.latestQuery];
      for (var qi = 0; qi < queries.length; qi++) {
        try {
          final results = await YoutubeService.instance.search(
            queries[qi],
            max: 30,
            dateFilter: qi == 1 ? YtDateFilter.month : YtDateFilter.relevance,
          );
          for (var i = 0; i < results.length; i++) {
            final item = results[i];
            final rankSignal =
                (1.0 - (i / 30.0)).clamp(0.0, 1.0).toDouble();
            final candidate = RadioCandidate.fromSong(
              item.toSong(),
              language: language,
              categoryHint: option.categoryHint,
              popularity: qi == 0 ? rankSignal : rankSignal * 0.35,
              recency: qi == 1 ? (0.30 + rankSignal * 0.50) : 0.12,
              isLatest: qi == 1,
            );
            final existingIndex = byId[item.id];
            if (existingIndex == null) {
              byId[item.id] = _candidates.length;
              _candidates.add(candidate);
            } else {
              final existing = _candidates[existingIndex];
              _candidates[existingIndex] = existing.copyWith(
                popularity: existing.popularity > candidate.popularity
                    ? existing.popularity
                    : candidate.popularity,
                recency: existing.recency > candidate.recency
                    ? existing.recency
                    : candidate.recency,
                isLatest: existing.isLatest || candidate.isLatest,
              );
            }
          }
        } catch (_) {
          // A single language/query failure must not kill the session.
        }
      }
    }
    if (_candidates.isEmpty) throw StateError('No radio candidates');
  }

  RadioCandidate? _pickNext({Set<String> excludeIds = const <String>{}}) {
    return _engine.pickNext(
      _candidates,
      selectedLanguages: widget.languages,
      excludeIds: excludeIds,
      recentLanguageCounts: _recentLanguageCounts,
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
    unawaited(_fillUpcoming());
    return true;
  }

  Future<bool> _playWithRecovery(RadioCandidate candidate, int token) async {
    if (!mounted || token != _candidateGeneration) return false;
    try {
      await audioHandler.playWithRetry(candidate.song);
    } catch (_) {}

    if (!mounted || token != _candidateGeneration) return false;
    if (audioHandler.player.playing) return true;

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
    if (_recoveringSongId == candidate.song.id && _recoveryFuture != null) {
      return _recoveryFuture!;
    }

    final completer = Completer<bool>();
    _recoveringSongId = candidate.song.id;
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
          if (audioHandler.player.playing) {
            recovered = true;
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
        if (_recoveringSongId == candidate.song.id) {
          _recoveringSongId = null;
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
    final songs = <Song>[];
    if (_current != null) songs.add(_current!.song);
    songs.addAll(_upcoming.map((c) => c.song));
    final next = songs.take(10).toList();

    for (final song in next) {
      if (song.thumb.isEmpty) continue;
      final provider = _artworkCache.putIfAbsent(song.id, () => NetworkImage(song.thumb));
      try {
        if (mounted) await precacheImage(provider, context);
      } catch (_) {}
    }
    _trimArtworkCache();

    // BUG FIX (Radio "subtitle" stuck-loading / slow skip — v58): tag this
    // prefetch pass with the candidate generation it started for. Once the
    // listener skips past this song, `_candidateGeneration` moves on and
    // this now-stale pass stops instead of continuing to burn bandwidth —
    // and compete with the *new* current song's own lyrics/audio fetch —
    // for songs nobody is listening to anymore.
    final gen = _candidateGeneration;
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
    unawaited(audioHandler.prefetchRadioSongs(next.take(5).toList()));
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
    _loadingNext = true;
    try {
      final used = <String>{
        if (_current != null) _current!.song.id,
        ..._upcoming.map((e) => e.song.id),
      };
      final fresh = _engine.buildLookAhead(
        _candidates,
        selectedLanguages: widget.languages,
        count: 10 - _upcoming.length,
        excludeIds: used,
        recentLanguageCounts: _recentLanguageCounts,
      );
      _upcoming.addAll(fresh);
    } finally {
      _loadingNext = false;
    }
    if (!mounted) return;
    setState(() {});
    unawaited(_preloadArtworkAndMetadata());
  }

  Future<void> _advance({required bool auto, String? failedSongId}) async {
    if (_current == null || _transitioning) return;
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
      } else if (!auto) {
        final seconds = audioHandler.player.position.inSeconds;
        await RadioHistoryStore.instance.markLatestAsSkipped(
          songId: old.song.id,
          skipPositionSec: seconds,
        );
        RadioService.instance.recordSkip(old.tags);
      } else {
        RadioService.instance.recordCompleted(old.tags);
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
    }
  }

  Future<void> _previous() async {
    if (_playedStack.isEmpty || _transitioning) return;
    setState(() => _transitioning = true); // FIX: dekho _advance() comment
    final previous = _playedStack.last;
    AppLogger.instance.log('[RADIO] _previous() called — jaa rahe hain: "${previous.song.title}"');
    try {
      final previousCandidate = _playedStack.removeLast();
      final current = _current;
      if (current != null) _upcoming.insert(0, current);
      if (!await _playCandidate(previousCandidate, addToHistory: false)) {
        AppLogger.instance.log('[RADIO] _previous() FAILED — "${previousCandidate.song.title}" play nahi hua.', level: 'ERROR');
        _engine.markFailed(previousCandidate.song.id);
      } else {
        AppLogger.instance.log('[RADIO] _previous() TASK COMPLETE — "${previousCandidate.song.title}" pe move hua.');
      }
    } finally {
      if (mounted) setState(() => _transitioning = false); // FIX: dekho upar
    }
  }

  Future<void> _togglePlay() async {
    AppLogger.instance.log('[RADIO] _togglePlay() called — abhi playing=${audioHandler.player.playing}');
    if (audioHandler.player.playing) {
      await audioHandler.pause();
      if (mounted) setState(() => _paused = true);
    } else {
      await audioHandler.play();
      if (mounted) setState(() => _paused = false);
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
    if (_liked) RadioService.instance.recordFavorite(current.tags);
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

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return WillPopScope(
      onWillPop: _onBackPressed,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: current == null
            ? _loadingBody()
            // FIX (user report: "swipe up/down poori screen pe kaam kare,
            // caption/lyrics wala chhota area tak limited na ho"): pehle
            // ye GestureDetector sirf andar `_buildContent()` ke ek
            // `Expanded` (topBar se lyrics tak) ke around tha — neeche
            // wali seekbar aur Next/Play/Favorite buttons wala poora
            // hissa iske BAHAR tha, isliye wahan swipe kaam hi nahi karta
            // tha. Ab poori Stack (poori screen) ke around hai — Slider
            // (seekbar) horizontal-drag use karta hai aur buttons tap use
            // karte hain, dono is VERTICAL-only drag detector se conflict
            // nahi karte (Flutter alag-alag gesture-axis independently
            // handle karta hai), isliye seekbar scrub aur button taps
            // bilkul pehle jaise hi kaam karte rahenge.
            : GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragEnd: (details) {
                  final v = details.primaryVelocity ?? 0;
                  if (v.abs() < 200) return;
                  if (v < 0) {
                    _swipedUp = true;
                    _advance(auto: false); // swipe up → agla gaana
                  } else {
                    _swipedUp = false;
                    _previous(); // swipe down → pichla gaana
                  }
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildArtwork(current),
                    Container(color: Colors.black.withOpacity(.55)),
                    SafeArea(
                      child: _buildContent(current),
                    ),
                  ],
                ),
              ),
      ),
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
                          duration: const Duration(milliseconds: 280),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, animation) {
                            // Reels jaisa hi: agla gaana (swipe up) neeche
                            // se upar aata hai, pichla gaana (swipe down)
                            // upar se neeche aata hai — fade ke saath.
                            final offsetAnim = Tween<Offset>(
                              begin: Offset(0, _swipedUp ? 0.12 : -0.12),
                              end: Offset.zero,
                            ).animate(animation);
                            return ClipRect(
                              child: SlideTransition(
                                position: offsetAnim,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
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
        IconButton(
          tooltip: 'Next song',
          iconSize: 34,
          color: _transitioning ? Colors.white38 : Colors.white,
          onPressed: _transitioning ? null : () => _advance(auto: false),
          icon: const Icon(Icons.skip_next_rounded),
        ),
        const SizedBox(width: 14),
        StreamBuilder<PlayerState>(
          stream: audioHandler.player.playerStateStream,
          builder: (_, snapshot) {
            final state = snapshot.data;
            final playing = state?.playing ?? audioHandler.player.playing;
            final processing = state?.processingState ?? audioHandler.player.processingState;
            // BUG FIX ("next dabao to bahut der tak kuch dikhta nahi,
            // jaise kaam hi nahi kiya" — v58): ye spinner pehle SIRF
            // just_audio ke apne processingState pe depend karta tha. Ek
            // Radio transition ka sabse pehla aur sabse lamba step (naye
            // gaane ka URL network se resolve karna) us player state ke
            // BADLE se pehle hi ho raha hota hai — `setUrl()`/`play()`
            // tabhi call hota hai jab URL mil chuka ho. Us poore intezaar
            // ke dauraan UI me koi spinner ya feedback nahi dikhta tha —
            // Next button bhi disabled ho jaane ke baad bhi hamesha safed
            // (enabled jaisa) hi dikhta tha (neeche dekho) — isliye tap
            // "kaam nahi kiya" jaisa lagta tha, jab tak (kabhi kaafi der
            // baad) gaana achanak badal na jaaye. Ab screen ka apna
            // `_loading`/`_transitioning` state bhi turant is spinner ko
            // trigger karta hai, chahe just_audio abhi tak apna internal
            // loading state dikha raha ho ya nahi.
            final buffering = _loading ||
                _transitioning ||
                processing == ProcessingState.loading ||
                processing == ProcessingState.buffering;
            return Semantics(
              button: true,
              label: buffering ? 'Buffering' : (playing ? 'Pause' : 'Play'),
              child: InkResponse(
                onTap: (_transitioning || buffering) ? null : _togglePlay,
                radius: 40,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: kGreen,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: kGreen.withOpacity(.28),
                        blurRadius: buffering ? 18 : 10,
                        spreadRadius: buffering ? 2 : 0,
                      ),
                    ],
                  ),
                  child: buffering
                      ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : Icon(
                          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 40,
                          color: Colors.white,
                        ),
                ),
              ),
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
  const RadioPlayerProgress({super.key, required this.player});

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
    if (!mounted || _dragging || !widget.player.playing) return;
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
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              min: 0,
              max: maxMs.toDouble(),
              value: valueMs,
              onChangeStart: (value) {
                setState(() {
                  _dragging = true;
                  _dragMs = value;
                });
              },
              onChanged: (value) {
                setState(() => _dragMs = value);
              },
              onChangeEnd: (value) async {
                setState(() {
                  _dragging = false;
                  _dragMs = value;
                });
                await widget.player.seek(Duration(milliseconds: value.round()));
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
    const itemExtent = 40.0;
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
            padding: const EdgeInsets.symmetric(vertical: 68),
            itemExtent: 40,
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
