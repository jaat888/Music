// lib/screens/full_player_screen.dart
// Full-screen player — vinyl, seek bar, controls, aur quick-access chips.

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
import '../services/sleep_timer_service.dart';
import '../services/youtube_service.dart';
import '../services/download_queue_service.dart';
import '../widgets/rotating_vinyl.dart';
import '../widgets/progress_slider.dart';
import '../widgets/animated_play_button.dart';
import '../widgets/loading_ring.dart';
import '../widgets/heart_button.dart';
import 'queue_screen.dart';
import 'lyrics_screen.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen> {
  // BUG FIX (Part 2): pehle yahan apna alag screen-local `Timer? _sleepTimer`
  // tha jo is screen ke dispose() hote hi cancel ho jaata tha (sleep timer
  // laga ke player screen band karo → silently off). Ab global
  // `SleepTimerService.instance` use hota hai — dekho us file ka comment.

  // NEW (2026-09-16, v15): mini player me download/radio buttons pehle se
  // the (dekho mini_player.dart), lekin full player screen me nahi —
  // isliye yahan bhi same behaviour add kiya, same in-progress spinner
  // pattern ke saath.
  //
  // BUG FIX (v38 — user report: "full screen player pe download icon fix
  // nahi hua"): v37 me DownloadQueueService add hoke home/artist/album/
  // liked/playlist/mood/smart screens migrate ho gaye the, lekin ye screen
  // chhoot gayi thi — abhi bhi seedha `YoutubeService.instance.download()`
  // call karti thi, apne alag local `_downloading` bool ke saath. Isse
  // download shared queue me register hi nahi hota tha (Downloads screen/
  // notification progress me nahi dikhta tha), aur agar dusri screen se
  // wahi gaana pehle se download ho raha ho to yahan duplicate download
  // shuru ho jaata. Ab `DownloadQueueService` use hota hai — `_downloading`
  // hata diya, icon seedha shared queue ke live state se driven hai.
  bool _startingRadio = false;

  @override
  void dispose() {
    super.dispose();
  }

  // BUG FIX (v38): ab baaki screens jaisa shared DownloadQueueService use
  // karta hai — dekho upar wala comment.
  Future<void> _handleDownload(Song song) async {
    if (DownloadQueueService.instance.isActive(song.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${song.title}" already download queue mein hai')),
      );
      return;
    }
    final already = await DownloadDB.instance.exists(song.id);
    if (!mounted) return;
    if (already) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ye gaana pehle se downloaded hai')),
      );
      return;
    }
    // PART 1 (WiFi-only downloads): download() ab khud bhi ye check karta
    // hai (root-level safety net), lekin yahan pehle hi bata dena behtar
    // UX hai — "Download fail ho gaya" generic message se zyada clear.
    if (!await YoutubeService.instance.canDownloadNow()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'WiFi-only downloads ON hai — WiFi se connect karke try karein',
          ),
        ),
      );
      return;
    }
    DownloadQueueService.instance.enqueue(song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${song.title}" download queue mein daal diya')),
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
    QueueService.instance.enableRadioMode(
      () => YoutubeService.instance.loadMoreRadioQueue(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Radio shuru — ${added.length} gaane queue me add ho gaye')),
    );
  }

  void _handleStopRadio() {
    QueueService.instance.disableRadioMode();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Radio band kar diya')),
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
    SleepTimerService.instance.startDuration(d);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${d.inMinutes} min baad music pause ho jayega')),
    );
  }

  // NEW (Part 2): "Song khatam hone tak" — agla gaana shuru hue bina,
  // current gaana khatam hote hi playback pause ho jaata hai.
  void _startEndOfTrackSleep() {
    SleepTimerService.instance.startEndOfTrack();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Current gaana khatam hote hi music pause ho jayega'),
      ),
    );
  }

  void _cancelSleepTimer() {
    SleepTimerService.instance.cancel();
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
              title: Text('Song khatam hone tak', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                _startEndOfTrackSleep();
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

  void _showSpeedDialog() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final current = audioHandler.currentSpeed;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Playback Speed', style: AppText.displayS()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in speeds)
              ListTile(
                title: Text(
                  '${s}x${s == 1.0 ? ' (Normal)' : ''}',
                  style: AppText.bodyL(
                    color: (current - s).abs() < 0.01 ? kGreen : null,
                  ),
                ),
                trailing: (current - s).abs() < 0.01
                    ? const Icon(Icons.check, color: kGreen)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  audioHandler.setSpeed(s);
                  setState(() {}); // chip label turant refresh ho
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
              leading: Icon(Icons.queue_music, color: kTextDim),
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
              leading: Icon(Icons.lyrics_outlined, color: kTextDim),
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

  // BUG FIX (2026-09-18 — user request: "button jaisa 4th image jaisa
  // banao"): pehle ye ek FILLED BOX (rounded square background) tha, jaisa
  // pehle screenshot me tha. User ne example diya — flat icon + chhota
  // label neeche, koi box/background nahi (jaisa most modern music apps
  // me hota hai). Ab wahi style — box hata diya, har action ke neeche
  // uska naam bhi dikhta hai.
  Widget _chip({required Widget child, required String label}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        const SizedBox(height: 2),
        Text(
          label,
          style: AppText.bodyS(color: kTextDim).copyWith(fontSize: 11),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final queueService = context.watch<QueueService>();
    // Sirf rebuild-trigger ke liye watch — heart chip ka isLiked FutureBuilder
    // se turant refresh ho jaaye jab bhi kahin se like/unlike ho.
    context.watch<LikeService>();
    // NEW (Part 2): sleep timer ab global service me hai — is screen ke
    // khule/band hone se bekhabar, dusri screen (settings) se set kiya ho
    // to bhi yahan sahi state dikhega.
    final sleepTimerActive = context.watch<SleepTimerService>().isActive;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration:  BoxDecoration(
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
                            icon:  Icon(
                              Icons.keyboard_arrow_down,
                              color: kText,
                              size: 30,
                            ),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(Icons.more_vert, color: kText),
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
                                          // NEW (2026-09-17, v66): explicit
                                          // phase-status (dekho
                                          // background_service.dart —
                                          // `artist` field ab KABHI
                                          // overwrite nahi hoti, isliye
                                          // status yahan explicitly
                                          // `audioHandler.phase` se dikhाते
                                          // hain, koi implicit/accidental
                                          // dependency nahi).
                                          ValueListenableBuilder<PlaybackPhase>(
                                            valueListenable: audioHandler.phase,
                                            builder: (context, phase, _) {
                                              String subtitle = song.artist;
                                              if (phase != PlaybackPhase.playing &&
                                                  phase != PlaybackPhase.paused &&
                                                  phase != PlaybackPhase.idle) {
                                                subtitle = audioHandler
                                                        .phaseMessage.value ??
                                                    switch (phase) {
                                                      PlaybackPhase.resolving =>
                                                        'Resolving...',
                                                      PlaybackPhase.verifying =>
                                                        'Verifying...',
                                                      PlaybackPhase.buffering =>
                                                        'Buffering...',
                                                      PlaybackPhase.retrying =>
                                                        'Retrying...',
                                                      PlaybackPhase.error =>
                                                        'Playback error',
                                                      _ => subtitle,
                                                    };
                                              }
                                              return Text(
                                                subtitle,
                                                style: AppText.bodyM(),
                                                textAlign: TextAlign.center,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              );
                                            },
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
                                              // NEW: buffered-progress —
                                              // chunked streaming me
                                              // "kitna load ho chuka hai"
                                              // dikhane ke liye (dekho
                                              // progress_slider.dart).
                                              return StreamBuilder<Duration>(
                                                key: ValueKey(
                                                    'buffered-${song.id}'),
                                                stream: audioHandler
                                                    .player.bufferedPositionStream,
                                                initialData: Duration.zero,
                                                builder: (context, bufSnap) {
                                                  return ProgressSlider(
                                                    position: pos,
                                                    total: total,
                                                    bufferedPosition:
                                                        bufSnap.data,
                                                    onSeek: (d) =>
                                                        audioHandler.seek(d),
                                                  );
                                                },
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    Row(
                                      // BUG FIX (v37 — "buttons ganda lagte
                                      // hain"): pehle `center` + sirf play
                                      // button ke aas-paas chhote manual
                                      // SizedBox gaps the — shuffle/repeat
                                      // dono edges ke paas ek saath chipke
                                      // rehte the aur beech mein bahut zyada
                                      // khaali jagah ban jaati thi (screenshot
                                      // wahi dikha raha tha). `spaceEvenly` se
                                      // saare 5 controls poori row-width mein
                                      // barabar-barabar spaced dikhte hain —
                                      // jaisa Spotify/YT Music jaise apps mein
                                      // hota hai.
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            Icons.shuffle,
                                            color: queueService.shuffle
                                                ? kGreen
                                                : kTextDim,
                                            // BUG FIX (v37): pehle iska koi
                                            // explicit size nahi tha (default
                                            // ~24, lekin skip_previous/next se
                                            // bahut chhota/dim dikh raha tha,
                                            // asymmetric lagta tha). Ab
                                            // shuffle/repeat dono ek jaisa
                                            // consistent size use karte hain.
                                            size: 22,
                                          ),
                                          onPressed: () =>
                                              _toggleShuffle(queueService),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.skip_previous,
                                            color: kText,
                                            // BUG FIX (v37): 44 bahut bada tha
                                            // — play button (70) ke bagal
                                            // mein bhi bhaari/unbalanced
                                            // dikhta tha. 34 par prev/next
                                            // clearly secondary lagte hain,
                                            // play button hi visually sabse
                                            // bada/primary rehta hai.
                                            size: 34,
                                          ),
                                          onPressed: () =>
                                              audioHandler.skipToPrevious(),
                                        ),
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
                                            final processingState = pbSnap
                                                .data?.processingState;
                                            final isError = processingState ==
                                                AudioProcessingState.error;
                                            if (isError) {
                                              return SizedBox(
                                                width: 70,
                                                height: 70,
                                                child: IconButton(
                                                  tooltip: 'Retry',
                                                  icon:  Icon(
                                                    Icons.refresh_rounded,
                                                    color: kText,
                                                  ),
                                                  iconSize: 40,
                                                  onPressed: () => audioHandler
                                                      .retryCurrent(),
                                                ),
                                              );
                                            }
                                            // NEW (2026-09-16, v15): gaana
                                            // change hote hi ye button turant
                                            // dikhta tha lekin player abhi
                                            // naya source load kar raha
                                            // hota tha (timestamp 00:00 pe
                                            // atka rehta) — isi beech user
                                            // tap kar deta to play/pause
                                            // state inconsistent ho jaati
                                            // thi. Ab loading/buffering ke
                                            // time button ke around ek
                                            // ghumta hua ring dikhta hai aur
                                            // uske taps bhi block ho jaate
                                            // hain jab tak naya gaana ready
                                            // na ho jaaye.
                                            final isLoading = processingState ==
                                                    AudioProcessingState
                                                        .loading ||
                                                processingState ==
                                                    AudioProcessingState
                                                        .buffering;
                                            return LoadingRing(
                                              isLoading: isLoading,
                                              size: 70,
                                              child: AnimatedPlayButton(
                                                isPlaying: isPlaying,
                                                size: 70,
                                                onTap: () => isPlaying
                                                    ? audioHandler.pause()
                                                    : audioHandler.play(),
                                              ),
                                            );
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.skip_next,
                                            color: kText,
                                            size: 34,
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
                                            size: 22,
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
                                            label: 'Like',
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
                                            label: 'Download',
                                            // BUG FIX (v38): ListenableBuilder
                                            // shared DownloadQueueService se
                                            // jud ke rakhta hai — jab bhi
                                            // koi bhi screen se (isi gaane
                                            // ko) queue/download/finish kare,
                                            // ye icon turant reflect karta
                                            // hai. Pehle sirf apna local
                                            // `_downloading` dekhta tha, jo
                                            // sirf isi screen ke button se
                                            // download shuru karne par set
                                            // hota tha.
                                            child: ListenableBuilder(
                                              listenable:
                                                  DownloadQueueService.instance,
                                              builder: (context, _) {
                                                final active =
                                                    DownloadQueueService
                                                        .instance
                                                        .isActive(song.id);
                                                return FutureBuilder<bool>(
                                                  // FIX: download icon ab
                                                  // "already downloaded"
                                                  // state ko reflect karta
                                                  // hai (green/filled), sirf
                                                  // static grey nahi rehta.
                                                  future: DownloadDB.instance
                                                      .exists(song.id),
                                                  builder: (context, dlSnap) {
                                                    final isDownloaded =
                                                        !active &&
                                                        (dlSnap.data ?? false);
                                                    return IconButton(
                                                      icon: active
                                                          ? SizedBox(
                                                              width: 18,
                                                              height: 18,
                                                              child:
                                                                  CircularProgressIndicator(
                                                                strokeWidth: 2,
                                                                color: kTextDim,
                                                              ),
                                                            )
                                                          : Icon(
                                                              isDownloaded
                                                                  ? Icons
                                                                      .download_done_rounded
                                                                  : Icons
                                                                      .download_rounded,
                                                              color: isDownloaded
                                                                  ? kGreen
                                                                  : kTextDim,
                                                            ),
                                                      tooltip: active
                                                          ? 'Download ho raha hai'
                                                          : (isDownloaded
                                                              ? 'Downloaded'
                                                              : 'Download'),
                                                      onPressed: active
                                                          ? null
                                                          : () =>
                                                              _handleDownload(
                                                                  song),
                                                    );
                                                  },
                                                );
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          _chip(
                                            label: 'Radio',
                                            child: IconButton(
                                              icon: _startingRadio
                                                  ?  SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: kTextDim,
                                                      ),
                                                    )
                                                  : Icon(
                                                      Icons.radio_rounded,
                                                      // FIX: radio mode
                                                      // "on" hone par icon
                                                      // green — pehle
                                                      // hamesha grey rehta
                                                      // tha chahe radio
                                                      // chal hi kyu na
                                                      // raha ho.
                                                      color:
                                                          queueService
                                                                  .radioMode
                                                              ? kGreen
                                                              : kTextDim,
                                                    ),
                                              tooltip: queueService.radioMode
                                                  ? 'Radio band karo'
                                                  : 'Radio shuru karo',
                                              onPressed: _startingRadio
                                                  ? null
                                                  : () => queueService
                                                          .radioMode
                                                      ? _handleStopRadio()
                                                      : _handleRadio(song),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          _chip(
                                            label: 'Queue',
                                            child: IconButton(
                                              icon:  Icon(
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
                                            label: 'Sleep',
                                            child: IconButton(
                                              icon: Icon(
                                                // FIX: sleep timer active
                                                // hone par icon green +
                                                // filled — pehle hamesha
                                                // grey outline hi rehta
                                                // tha, on/off pata hi
                                                // nahi chalta tha.
                                                sleepTimerActive
                                                    ? Icons.timer
                                                    : Icons.timer_outlined,
                                                color: sleepTimerActive
                                                    ? kGreen
                                                    : kTextDim,
                                              ),
                                              onPressed: _showSleepTimerDialog,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          _chip(
                                            label: 'Speed',
                                            child: IconButton(
                                              icon: Icon(
                                                Icons.speed,
                                                // PART 1: 1.0x (normal) pe
                                                // grey, kisi aur speed pe
                                                // green — jaise sleep-timer
                                                // chip "on" state dikhata
                                                // hai.
                                                color: (audioHandler
                                                                .currentSpeed -
                                                            1.0)
                                                        .abs() <
                                                    0.01
                                                    ? kTextDim
                                                    : kGreen,
                                              ),
                                              tooltip:
                                                  '${audioHandler.currentSpeed}x speed',
                                              onPressed: _showSpeedDialog,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          _chip(
                                            label: 'Lyrics',
                                            child: IconButton(
                                              icon:  Icon(
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
