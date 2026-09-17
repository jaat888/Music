// lib/screens/radio_player_screen.dart
// SurSathi v55 Radio Enhanced — same Radio UI, hardened transition/playback layer.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
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
        _candidates.add(last);
        started = await _playCandidate(last, addToHistory: false);
        if (!started) {
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
          started = await _playCandidate(candidate, addToHistory: true);
          if (!started) _engine.markFailed(candidate.song.id);
        }
      }
      if (!started) throw StateError('No playable radio candidate');
      unawaited(_fillUpcoming());
    } catch (_) {
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
    _liked = await LikeService.instance.isLiked(candidate.song.id);
    if (!mounted || token != _candidateGeneration) return false;

    _engine.setLiked(candidate.song.id, _liked);
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
      return false;
    }

    _recentLanguageCounts[candidate.language.toLowerCase()] =
        (_recentLanguageCounts[candidate.language.toLowerCase()] ?? 0) + 1;
    _engine.markPlayed(candidate.song.id);
    setState(() => _loading = false);

    if (addToHistory) {
      await RadioHistoryStore.instance.record(
        songId: candidate.song.id,
        title: candidate.song.title,
        tags: candidate.tags,
        language: candidate.language,
        artist: candidate.song.artist,
        duration: candidate.song.duration,
        wasSkipped: false,
      );
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
    if (!mounted || _current?.song.id != song.id) return;
    final token = _candidateGeneration;
    final candidate = _current!;
    final recovered = await _ensureRecovery(
      candidate,
      token,
      autoAdvanceOnFailure: true,
    );
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
            break;
          }
          try {
            await audioHandler.playWithRetry(candidate.song);
          } catch (_) {}
          if (audioHandler.player.playing) {
            recovered = true;
            if (mounted) setState(() => _loading = false);
            break;
          }
        }

        if (!recovered && mounted && _current?.song.id == candidate.song.id) {
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

    unawaited(
      LyricsService.instance.prefetchForSongs(
        next,
        maxSongs: 10,
      ),
    );
    unawaited(audioHandler.prefetchRadioSongs(next.take(2).toList()));
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
    _transitioning = true;
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
      _upcoming.removeWhere((item) => item.song.id == failedSongId);

      for (var attempt = 0; attempt < 12; attempt++) {
        RadioCandidate? next;
        if (_upcoming.isNotEmpty) {
          next = _upcoming.removeAt(0);
        } else {
          next = _pickNext(
            excludeIds: {
              old.song.id,
              ..._playedStack.map((e) => e.song.id),
            },
          );
        }
        if (next == null) {
          await _fetchCandidates();
          next = _pickNext(
            excludeIds: {old.song.id, ..._playedStack.map((e) => e.song.id)},
          );
        }
        if (next == null || !mounted) return;

        final ok = await _playCandidate(next, addToHistory: true);
        if (ok) return;
        _engine.markFailed(next.song.id);
        _upcoming.removeWhere((item) => item.song.id == next!.song.id);
      }
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _previous() async {
    if (_playedStack.isEmpty || _transitioning) return;
    _transitioning = true;
    try {
      final previous = _playedStack.removeLast();
      final current = _current;
      if (current != null) _upcoming.insert(0, current);
      if (!await _playCandidate(previous, addToHistory: false)) {
        _engine.markFailed(previous.song.id);
      }
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _togglePlay() async {
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

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      backgroundColor: Colors.black,
      body: current == null
          ? _loadingBody()
          : Stack(
              fit: StackFit.expand,
              children: [
                _buildArtwork(current),
                Container(color: Colors.black.withOpacity(.55)),
                SafeArea(
                  child: _buildContent(current),
                ),
              ],
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
              SizedBox(height: 48, child: _topBar()),
              SizedBox(height: compact ? 14 : 24),
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
              Text(
                current.song.artist,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyM(color: Colors.white70),
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
          color: Colors.white,
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
            final buffering = processing == ProcessingState.loading ||
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

class _RadioLyricsState extends State<RadioLyrics>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _ticker;
  int _activeIndex = -1;
  List<LyricLine> _lines = const [];

  @override
  void initState() {
    super.initState();
    _lines = widget.result?.synced ?? const [];
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_syncActiveLine)..repeat();
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
    _ticker
      ..removeListener(_syncActiveLine)
      ..dispose();
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

  void _syncActiveLine() {
    if (!mounted || _lines.isEmpty) return;
    final next = _findActive(widgetPlayerPosition);
    if (next == _activeIndex) return;
    setState(() => _activeIndex = next);
    _centerActive(next);
  }

  Duration get widgetPlayerPosition => audioHandler.player.position;

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
