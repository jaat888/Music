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
import '../db/download_db.dart';
import '../services/background_service.dart';
import '../services/queue_service.dart';
import '../services/like_service.dart';
import '../services/youtube_service.dart';
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

  // NEW (2026-09-16, v15): mini player me download/radio buttons pehle se
  // the (dekho mini_player.dart), lekin full player screen me nahi —
  // isliye yahan bhi same behaviour add kiya, same in-progress spinner
  // pattern ke saath.
  bool _downloading = false;
  bool _startingRadio = false;

  @override
  void dispose() {
    _sleepTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleDownload(Song song) async {
    if (_downloading) return;
    final already = await DownloadDB.instance.exists(song.id);
    if (!mounted) return;
    if (already) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ye gaana pehle se downloaded hai')),
      );
      return;
    }
    setState(() => _downloading = true);
    final path = await YoutubeService.instance.download(
      song.id,
      song.title,
      author: song.artist,
    );
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path != null ? '${song.title} download ho gaya' : 'Download fail ho gaya',
        ),
      ),
    );
  }

  Future<void> _handleRadio(Song song) async {
    if (_startingRadio) return;
    setState(() => _startingRadio = true);
    final added = await YoutubeService.instance.getRadioQueue(
      song.id,
      song.title,
      song.artist,
    );
    if (!mounted) return;
    setState(() => _startingRadio = false);
    if (added.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Radio ke liye gaane nahi mile')),
      );
      return;
    }
    QueueService.instance.addAll(added);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Radio shuru — ${added.length} gaane queue me add ho gaye')),
    );
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
                                      // BUG FIX (2026-09-16, v10): "gaana
                                      // change karne pe time delay". Ye
                                      // StreamBuilder pehle bina key ke tha,
                                      // isliye jab mediaItem (photo/naam)
                                      // turant switch ho jaata tha, ye apna
                                      // PURANA cached duration/position
                                      // dikhata rehta tha — kyunki
                                      // durationStream/positionStream tab
                                      // tak naya value emit hi nahi karte
                                      // jab tak naye source ka setUrl/
                                      // setFilePath poora load na ho jaaye.
                                      // Ab ValueKey(song.id) lagaya hai —
                                      // gaana badalte hi ye StreamBuilders
                                      // fresh restart hote hain (purana
                                      // cached value turant clear), aur
                                      // total ke liye turant mediaItem.
                                      // duration (jo already pata hai)
                                      // fallback ke roop me use hota hai
                                      // jab tak player khud apna duration
                                      // resolve na kar le — isse "0:00"
                                      // flash bhi nahi hota.
                                      child: StreamBuilder<Duration?>(
                                        key: ValueKey('duration-${song.id}'),
                                        stream:
                                            audioHandler.player.durationStream,
                                        initialData: mediaItem?.duration,
                                        builder: (context, durSnap) {
                                          final total = durSnap.data ??
                                              mediaItem?.duration ??
                                              Duration.zero;
                                          return StreamBuilder<Duration>(
                                            key: ValueKey('position-${song.id}'),
                                            stream: audioHandler
                                                .player.positionStream,
                                            initialData: Duration.zero,
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
                                    // NEW (2026-09-16, v15): download+radio
                                    // chips add hone se ab 6 chips ho gaye
                                    // — spaceEvenly Row chhoti screens
                                    // (~360dp se kam) pe overflow kar
                                    // sakta tha, isliye horizontally
                                    // scrollable bana diya (jaisi screen
                                    // utne chips fit karegi, baaki side-
                                    // scroll se milenge).
                                    LayoutBuilder(
                                      builder: (context, constraints) =>
                                          SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        child: ConstrainedBox(
                                          // Jab sab 6 chips available
                                          // width me fit ho jaayein, Row
                                          // ko poori width diya jaata hai
                                          // taaki spaceEvenly pehle jaisa
                                          // hi evenly-spaced/centered
                                          // dikhe. Jab fit na ho (chhoti
                                          // screen), Row apni natural
                                          // (chhoti) width leta hai aur
                                          // SingleChildScrollView side-
                                          // scroll allow karta hai.
                                          constraints: BoxConstraints(
                                            minWidth: constraints.maxWidth -
                                                32, // horizontal padding
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
                                          const SizedBox(width: 10),
                                          _chip(
                                            child: IconButton(
                                              icon: _downloading
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: kTextDim,
                                                      ),
                                                    )
                                                  : const Icon(
                                                      Icons.download_rounded,
                                                      color: kTextDim,
                                                    ),
                                              tooltip: 'Download',
                                              onPressed: _downloading
                                                  ? null
                                                  : () => _handleDownload(song),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          _chip(
                                            child: IconButton(
                                              icon: _startingRadio
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: kTextDim,
                                                      ),
                                                    )
                                                  : const Icon(
                                                      Icons.radio_rounded,
                                                      color: kTextDim,
                                                    ),
                                              tooltip: 'Radio shuru karo',
                                              onPressed: _startingRadio
                                                  ? null
                                                  : () => _handleRadio(song),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
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
                                          const SizedBox(width: 10),
                                          _chip(
                                            child: IconButton(
                                              icon: const Icon(
                                                Icons.timer_outlined,
                                                color: kTextDim,
                                              ),
                                              onPressed: _showSleepTimerDialog,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
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
