// lib/screens/full_player_screen.dart
// Full-screen player — vinyl, seek bar, controls, aur quick-access chips.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/queue_service.dart';
import '../services/like_service.dart';
import '../widgets/rotating_vinyl.dart';
import '../widgets/progress_slider.dart';
import '../widgets/animated_play_button.dart';
import '../widgets/heart_button.dart';
import 'queue_screen.dart';
import 'lyrics_screen.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen> {
  Timer? _sleepTimer;

  @override
  void dispose() {
    _sleepTimer?.cancel();
    super.dispose();
  }

  // MediaItem (audioHandler.mediaItem) se ek poora Song object banao —
  // heart/lyrics jaisi features ko poore Song model ki zaroorat padti hai.
  Song _songFromMediaItem(MediaItem item) {
    return Song(
      id: item.id,
      title: item.title,
      artist: item.artist ?? 'Unknown Artist',
      thumb: item.artUri?.toString() ?? '',
      duration: item.duration?.inSeconds ?? 0,
      filePath: item.extras?['filePath'] as String?,
    );
  }

  IconData _repeatIcon(SurRepeatMode mode) {
    switch (mode) {
      case SurRepeatMode.one:
        return Icons.repeat_one;
      case SurRepeatMode.all:
      case SurRepeatMode.off:
        return Icons.repeat;
    }
  }

  void _cycleRepeat(QueueService qs) {
    final next = switch (qs.repeat) {
      SurRepeatMode.off => SurRepeatMode.all,
      SurRepeatMode.all => SurRepeatMode.one,
      SurRepeatMode.one => SurRepeatMode.off,
    };
    final serviceMode = switch (next) {
      SurRepeatMode.off => AudioServiceRepeatMode.none,
      SurRepeatMode.all => AudioServiceRepeatMode.all,
      SurRepeatMode.one => AudioServiceRepeatMode.one,
    };
    audioHandler.setRepeatMode(serviceMode);
  }

  void _toggleShuffle(QueueService qs) {
    final mode =
        qs.shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all;
    audioHandler.setShuffleMode(mode);
  }

  void _startSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(d, () => audioHandler.pause());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${d.inMinutes} min baad music pause ho jayega')),
    );
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sleep timer off kar diya')),
    );
  }

  void _showSleepTimerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Sleep Timer', style: AppText.displayS()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mins in [15, 30, 60, 90])
              ListTile(
                title: Text('$mins minute', style: AppText.bodyL()),
                onTap: () {
                  Navigator.pop(ctx);
                  _startSleepTimer(Duration(minutes: mins));
                },
              ),
            ListTile(
              title: Text('Off', style: AppText.bodyL(color: kTextDim)),
              onTap: () {
                Navigator.pop(ctx);
                _cancelSleepTimer();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMoreOptions(Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBgElev,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.queue_music, color: kTextDim),
              title: Text('Queue dekho', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const QueueScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.lyrics_outlined, color: kTextDim),
              title: Text('Lyrics dekho', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => LyricsScreen(song: song)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final queueService = context.watch<QueueService>();
    // Sirf rebuild-trigger ke liye watch — heart chip ka isLiked FutureBuilder
    // se turant refresh ho jaaye jab bhi kahin se like/unlike ho.
    context.watch<LikeService>();

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kBgElev, kBg],
          ),
        ),
        child: SafeArea(
          child: GestureDetector(
            // Neeche ki taraf tez swipe pe player band karo
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 300) {
                Navigator.of(context).maybePop();
              }
            },
            child: StreamBuilder<MediaItem?>(
              stream: audioHandler.mediaItem,
              builder: (context, mediaSnap) {
                final mediaItem = mediaSnap.data;
                final song =
                    mediaItem == null ? null : _songFromMediaItem(mediaItem);

                return Column(
                  children: [
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: kText,
                              size: 30,
                            ),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.more_vert, color: kText),
                            onPressed: song == null
                                ? null
                                : () => _showMoreOptions(song),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: song == null
                          ? Center(
                              child: Text(
                                'Kuch nahi chal raha',
                                style: AppText.bodyL(color: kTextDim),
                              ),
                            )
                          : StreamBuilder<ja.PlayerState>(
                              stream: audioHandler.player.playerStateStream,
                              builder: (context, playerStateSnap) {
                                final isPlaying =
                                    playerStateSnap.data?.playing ?? false;

                                return Column(
                                  children: [
                                    const SizedBox(height: 20),
                                    Hero(
                                      tag: 'thumb-${song.id}',
                                      child: RotatingVinyl(
                                        imageUrl: song.thumb,
                                        size: 260,
                                        isPlaying: isPlaying,
                                      ),
                                    ),
                                    const SizedBox(height: 30),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Column(
                                        children: [
                                          Text(
                                            song.title,
                                            style: AppText.displayS(),
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            song.artist,
                                            style: AppText.bodyM(),
                                            textAlign: TextAlign.center,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: StreamBuilder<Duration?>(
                                        stream:
                                            audioHandler.player.durationStream,
                                        builder: (context, durSnap) {
                                          final total =
                                              durSnap.data ?? Duration.zero;
                                          return StreamBuilder<Duration>(
                                            stream: audioHandler
                                                .player.positionStream,
                                            builder: (context, posSnap) {
                                              final pos = posSnap.data ??
                                                  Duration.zero;
                                              return ProgressSlider(
                                                position: pos,
                                                total: total,
                                                onSeek: (d) =>
                                                    audioHandler.seek(d),
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            Icons.shuffle,
                                            color: queueService.shuffle
                                                ? kGreen
                                                : kTextDim,
                                          ),
                                          onPressed: () =>
                                              _toggleShuffle(queueService),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.skip_previous,
                                            color: kText,
                                            size: 44,
                                          ),
                                          onPressed: () =>
                                              audioHandler.skipToPrevious(),
                                        ),
                                        const SizedBox(width: 8),
                                        // NEW (2026-09-16): error state me
                                        // pehle bhi yahi AnimatedPlayButton
                                        // dikhta rehta tha (isPlaying=false
                                        // hone se "play" icon), tap karne pe
                                        // kuch nahi hota tha (koi resolved
                                        // URL/source hi nahi hai player me).
                                        // Ab processingState==error pe ek
                                        // Retry button dikhta hai jo
                                        // currentSong ko dobara resolve
                                        // karta hai.
                                        StreamBuilder<PlaybackState>(
                                          stream: audioHandler.playbackState,
                                          builder: (context, pbSnap) {
                                            final isError = pbSnap.data
                                                    ?.processingState ==
                                                AudioProcessingState.error;
                                            if (isError) {
                                              return SizedBox(
                                                width: 70,
                                                height: 70,
                                                child: IconButton(
                                                  tooltip: 'Retry',
                                                  icon: const Icon(
                                                    Icons.refresh_rounded,
                                                    color: kText,
                                                  ),
                                                  iconSize: 40,
                                                  onPressed: () => audioHandler
                                                      .retryCurrent(),
                                                ),
                                              );
                                            }
                                            return AnimatedPlayButton(
                                              isPlaying: isPlaying,
                                              size: 70,
                                              onTap: () => isPlaying
                                                  ? audioHandler.pause()
                                                  : audioHandler.play(),
                                            );
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.skip_next,
                                            color: kText,
                                            size: 44,
                                          ),
                                          onPressed: () =>
                                              audioHandler.skipToNext(),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            _repeatIcon(queueService.repeat),
                                            color:
                                                queueService.repeat ==
                                                        SurRepeatMode.off
                                                    ? kTextDim
                                                    : kGreen,
                                          ),
                                          onPressed: () =>
                                              _cycleRepeat(queueService),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 20),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: [
                                          _chip(
                                            child: FutureBuilder<bool>(
                                              future: LikeService.instance
                                                  .isLiked(song.id),
                                              builder: (context, likeSnap) {
                                                return HeartButton(
                                                  isLiked:
                                                      likeSnap.data ?? false,
                                                  size: 22,
                                                  onTap: () => context
                                                      .read<LikeService>()
                                                      .toggleLike(song),
                                                );
                                              },
                                            ),
                                          ),
                                          _chip(
                                            child: IconButton(
                                              icon: const Icon(
                                                Icons.queue_music,
                                                color: kTextDim,
                                              ),
                                              onPressed: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      const QueueScreen(),
                                                ),
                                              ),
                                            ),
                                          ),
                                          _chip(
                                            child: IconButton(
                                              icon: const Icon(
                                                Icons.timer_outlined,
                                                color: kTextDim,
                                              ),
                                              onPressed: _showSleepTimerDialog,
                                            ),
                                          ),
                                          _chip(
                                            child: IconButton(
                                              icon: const Icon(
                                                Icons.lyrics_outlined,
                                                color: kTextDim,
                                              ),
                                              onPressed: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      LyricsScreen(song: song),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Spacer(),
                                  ],
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
