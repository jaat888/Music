// lib/screens/radio_player_screen.dart
// Part 8 — Phase 5: Radio Player.
// Reel-style UI + swipe skip + previous + favorite + auto-next.
// Playback always goes through the existing audioHandler.playWithRetry().

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/radio_engine.dart';
import '../services/lyrics_service.dart';
import '../services/radio_history_store.dart';
import '../services/radio_service.dart';
import '../services/youtube_service.dart';
import 'radio_language_select_screen.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

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
  StreamSubscription<ProcessingState>? _completionSub;

  RadioCandidate? _current;
  bool _loading = true;
  bool _loadingNext = false;
  bool _paused = false;
  bool _liked = false;
  LyricsResult? _lyrics;
  bool _lyricsLoading = false;
  String? _error;
  int _generation = 0;
  // Part 12 hardening: serialize swipe/auto-next/previous transitions so a
  // fast double swipe cannot start two Radio songs at the same time.
  bool _transitioning = false;

  @override
  void initState() {
    super.initState();
    // Radio owns end-of-track transitions. The global AudioHandler completion
    // listener is told to stay out while this screen is active, preventing a
    // completed Radio track from advancing both QueueService and Radio.
    audioHandler.setRadioPlaybackOwned(
      true,
      onNext: () => _advance(auto: false),
      onPrevious: _previous,
    );
    _completionSub = audioHandler.player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && mounted && _current != null && !_transitioning) {
        _advance(auto: true);
      }
    });
    _start();
  }

  @override
  void dispose() {
    _completionSub?.cancel();
    // Radio must not keep playing after the screen is gone. Release ownership
    // immediately, then stop the player; stop() moves processingState to idle,
    // so it cannot create a completion event for QueueService.
    audioHandler.setRadioPlaybackOwned(false);
    unawaited(audioHandler.stop());
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _fetchCandidates();
      if (!mounted || generation != _generation) return;
      await _playCandidate(_pickInitial(), addToHistory: true);
    } catch (e) {
      if (!mounted || generation != _generation) return;
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
            // Search position is only a weak proxy for popularity. Latest-mode
            // position becomes a continuous relative-recency hint (newer
            // results near the front score a little higher, never exclusively).
            final rankSignal = (1.0 - (i / 30.0)).clamp(0.0, 1.0).toDouble();
            final popularity = qi == 0 ? rankSignal : rankSignal * 0.35;
            final recency = qi == 1 ? (0.30 + rankSignal * 0.50) : 0.12;
            final candidate = RadioCandidate.fromSong(
              item.toSong(),
              language: language,
              categoryHint: option.categoryHint,
              popularity: popularity,
              recency: recency,
              isLatest: qi == 1,
            );

            final existingIndex = byId[item.id];
            if (existingIndex == null) {
              byId[item.id] = _candidates.length;
              _candidates.add(candidate);
            } else {
              // Preserve both signals when one video appears in both searches.
              // Previously the first (hits) result discarded its latest flag.
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
          // One query/language failing must not kill the whole radio session.
        }
      }
    }
    if (_candidates.isEmpty) throw StateError('No radio candidates');
  }

  RadioCandidate? _pickInitial() {
    return _engine.pickNext(
      _candidates,
      selectedLanguages: widget.languages,
    );
  }

  Future<void> _playCandidate(RadioCandidate? candidate, {required bool addToHistory}) async {
    if (candidate == null) throw StateError('No next song');

    // Do not mark a candidate current/started until the actual player has
    // successfully started. A failed resolve/play must not poison the UI.
    await audioHandler.playWithRetry(candidate.song);
    if (!audioHandler.player.playing) {
      throw StateError('Radio playback did not start');
    }
    if (!mounted) return;

    _current = candidate;
    _paused = false;
    _liked = await LikeService.instance.isLiked(candidate.song.id);
    _loadLyrics(candidate.song);

    if (mounted) setState(() => _loading = false);

    if (addToHistory) {
      await RadioHistoryStore.instance.record(
        songId: candidate.song.id,
        title: candidate.song.title,
        tags: candidate.tags,
        language: candidate.language,
        wasSkipped: false,
      );
    }
    await _fillUpcoming();
  }

  Future<void> _loadLyrics(Song song) async {
    if (!mounted) return;
    setState(() {
      _lyricsLoading = true;
      _lyrics = null;
    });
    try {
      final result = await LyricsService.instance.getForSong(
        songId: song.id,
        title: song.title,
        artist: song.artist,
        durationSeconds: song.duration,
      );
      if (!mounted || _current?.song.id != song.id) return;
      setState(() {
        _lyrics = result;
        _lyricsLoading = false;
      });
    } catch (_) {
      if (mounted && _current?.song.id == song.id) {
        setState(() {
          _lyrics = null;
          _lyricsLoading = false;
        });
      }
    }
  }

  int _activeLyricIndex(Duration position, List<LyricLine> lines) {
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  Widget _lyricsStrip() {
    final result = _lyrics;
    if (_lyricsLoading) {
      return const SizedBox(
        height: 34,
        child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (result == null || !result.hasSynced) return const SizedBox.shrink();
    final lines = result.synced!;
    return StreamBuilder<Duration>(
      stream: audioHandler.player.positionStream,
      initialData: Duration.zero,
      builder: (_, snapshot) {
        final index = _activeLyricIndex(snapshot.data ?? Duration.zero, lines);
        final text = index >= 0 ? lines[index].text : '';
        final next = index + 1 < lines.length ? lines[index + 1].text : '';
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: SizedBox(
            key: ValueKey('$index-$text'),
            height: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  style: AppText.bodyM(color: Colors.white).copyWith(fontWeight: FontWeight.w700)),
                if (next.isNotEmpty)
                  Text(next, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                    style: AppText.bodyS(color: Colors.white54)),
              ],
            ),
          ),
        );
      },
    );
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
        count: 4 - _upcoming.length,
        excludeIds: used,
      );
      _upcoming.addAll(fresh);
    } finally {
      _loadingNext = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _advance({required bool auto}) async {
    if (_current == null || _transitioning) return;
    _transitioning = true;
    try {
    final old = _current!;
    if (!auto) {
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
    RadioCandidate? next;
    if (_upcoming.isNotEmpty) {
      next = _upcoming.removeAt(0);
    } else {
      next = _engine.pickNext(
        _candidates,
        selectedLanguages: widget.languages,
        excludeIds: {old.song.id, ..._playedStack.map((e) => e.song.id)},
      );
    }
    if (next == null) {
      await _fetchCandidates();
      next = _engine.pickNext(
        _candidates,
        selectedLanguages: widget.languages,
        excludeIds: {old.song.id},
      );
    }
    if (next == null || !mounted) return;
    setState(() => _loading = true);
    try {
      await _playCandidate(next, addToHistory: true);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _previous() async {
    if (_playedStack.isEmpty || _transitioning) return;
    _transitioning = true;
    final previous = _playedStack.removeLast();
    final current = _current;
    if (current != null) _upcoming.insert(0, current);
    setState(() => _loading = true);
    try {
      // Previous is navigation, not a new radio recommendation. It therefore
      // does not apply skip penalty and does not create a duplicate history
      // record; the original play record remains the non-repeat marker.
      await _playCandidate(previous, addToHistory: false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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

    _generation++;
    RadioService.instance.resetRadioSession();
    await audioHandler.pause();
    if (!mounted) return;

    // Language screen reads the saved selection, so it opens with the
    // previous choices already selected as required by the roadmap.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RadioLanguageSelectScreen()),
      (route) => route.isFirst,
    );
  }

  Future<void> _toggleLike() async {
    final current = _current;
    if (current == null) return;
    await LikeService.instance.toggleLike(current.song);
    if (mounted) {
      setState(() => _liked = !_liked);
      if (_liked) RadioService.instance.recordFavorite(current.tags);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: current == null
            ? _loadingBody()
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -350) _advance(auto: false);
                  if (velocity > 350) _previous();
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (current.song.thumb.isNotEmpty)
                      Image.network(
                        current.song.thumb,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(),
                      ),
                    Container(color: Colors.black.withOpacity(.55)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 14, 22, 26),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Back',
                                color: Colors.white,
                                icon: const Icon(Icons.keyboard_arrow_down, size: 30),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              const Spacer(),
                              Text('RADIO', style: AppText.titleM(color: Colors.white)),
                              const Spacer(),
                              PopupMenuButton<String>(
                                tooltip: 'Radio menu',
                                icon: const Icon(Icons.menu, color: Colors.white),
                                onSelected: (value) {
                                  if (value == 'reset') _confirmResetAndChangeLanguage();
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem<String>(
                                    value: 'reset',
                                    child: Text('Reset & Change Language'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            current.language.toUpperCase(),
                            style: AppText.bodyS(color: Colors.white70),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            current.song.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.displayL(color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            current.song.artist,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyM(color: Colors.white70),
                          ),
                          const SizedBox(height: 16),
                          _lyricsStrip(),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: 'Previous',
                                iconSize: 34,
                                color: Colors.white,
                                onPressed: _playedStack.isEmpty ? null : _previous,
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                              const SizedBox(width: 14),
                              StreamBuilder<PlayerState>(
                                stream: audioHandler.player.playerStateStream,
                                builder: (_, snapshot) {
                                  final playing = snapshot.data?.playing ?? !_paused;
                                  return InkResponse(
                                    onTap: _togglePlay,
                                    radius: 38,
                                    child: CircleAvatar(
                                      radius: 32,
                                      backgroundColor: kGreen,
                                      child: Icon(
                                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        size: 38,
                                        color: Colors.white,
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
                          ),
                          const SizedBox(height: 22),
                          Text(
                            '↑ Swipe up = Skip    ↓ Swipe down = Previous',
                            style: AppText.bodyS(color: Colors.white60),
                          ),
                          const SizedBox(height: 8),
                          if (_loading || _loadingNext)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text('${_upcoming.length} songs ready', style: AppText.bodyS(color: Colors.white54)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _loadingBody() {
    return Center(
      child: _error == null
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, color: Colors.white70, size: 44),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(onPressed: _start, icon: const Icon(Icons.refresh), label: const Text('Retry')),
              ],
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
