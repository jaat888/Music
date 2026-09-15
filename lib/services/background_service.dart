// lib/services/background_service.dart
// SABSE ZAROORI FILE — actual playback yahi se hota hai. audio_service ke
// BaseAudioHandler ko implement karta hai taaki background play, notification
// controls, aur lock screen controls sab kaam karein.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../db/cache_db.dart';
import '../models/song.dart';
import 'cache_service.dart';
import 'like_service.dart';
import 'queue_service.dart';
import 'youtube_service.dart';

// Global instance — poore app me yahi ek handler use hoga
late SurSathiAudioHandler audioHandler;

// AudioService.init() ka wrapper — main() me isko call karna hai
Future<void> initAudioHandler() async {
  audioHandler = await AudioService.init(
    builder: () => SurSathiAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.sursathi.audio',
      androidNotificationChannelName: 'SurSathi Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      preloadArtwork: true,
    ),
  );
}

class SurSathiAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();

  SurSathiAudioHandler() {
    // just_audio ke playback events ko audio_service ke playbackState me map karo
    player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        // Stream error (network drop, bad url) — processing state idle kar do
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            playing: false,
          ),
        );
      },
    );

    // Player khud khatam ho jaye (song end) to agla song bajao
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        skipToNext();
      }
    });
  }

  // ---------------- State broadcast ----------------

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[player.processingState]!,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: event.bufferedPosition,
        speed: player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }

  // ---------------- Base controls ----------------

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    QueueService.instance.next();
    await _playCurrentFromQueue();
  }

  @override
  Future<void> skipToPrevious() async {
    QueueService.instance.previous();
    await _playCurrentFromQueue();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final on = shuffleMode != AudioServiceShuffleMode.none;
    QueueService.instance.setShuffle(on);
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        QueueService.instance.setRepeat(SurRepeatMode.off);
        break;
      case AudioServiceRepeatMode.one:
        QueueService.instance.setRepeat(SurRepeatMode.one);
        break;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        QueueService.instance.setRepeat(SurRepeatMode.all);
        break;
    }
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  // ---------------- Custom playback methods ----------------

  // Streaming URL se seedha play karo (YouTube stream)
  Future<void> playSong(Song song, String url) async {
    mediaItem.add(_toMediaItem(song));
    try {
      await player.setUrl(url);
      await player.play();
      // Cache background me ho jaaye — playback ruke bina
      unawaited(_autoCacheInBackground(song, url));
    } catch (e) {
      // URL kharab nikla — processing state error kar do, UI ko pata chal jaaye
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          playing: false,
        ),
      );
    }
  }

  // Stream URL fetch karne me thoda flaky hota hai YouTube ka — 3 baar try karo
  Future<void> playWithRetry(
    Song song,
    Future<String?> Function(String videoId) urlFetcher,
  ) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      final url = await urlFetcher(song.id);
      if (url != null) {
        await playSong(song, url);
        return;
      }
      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    // Teeno attempts fail — error state
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
      ),
    );
  }

  // Local file se play karo — downloaded ya already-cached songs ke liye
  Future<void> playFromFile(Song song, String filePath) async {
    mediaItem.add(_toMediaItem(song.copyWith(filePath: filePath)));
    try {
      await player.setFilePath(filePath);
      await player.play();
    } catch (e) {
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          playing: false,
        ),
      );
    }
  }

  // ---------------- Helpers ----------------

  // QueueService ke current index ke hisaab se sahi source (local ya stream) se play
  Future<void> _playCurrentFromQueue() async {
    final song = QueueService.instance.currentSong;
    if (song == null) {
      await stop();
      return;
    }

    if (song.filePath != null && await File(song.filePath!).exists()) {
      await playFromFile(song, song.filePath!);
    } else {
      await playWithRetry(song, YoutubeService.instance.getAudioUrl);
    }
  }

  MediaItem _toMediaItem(Song song) {
    return MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      artUri: song.thumb.isNotEmpty ? Uri.tryParse(song.thumb) : null,
      duration: Duration(seconds: song.duration),
      extras: {'filePath': song.filePath},
    );
  }

  // Stream ho raha song ko chupke se cache folder me download karke DB me
  // register karo — agli baar bina internet ke bhi bajega. Playback isse
  // block nahi hota, isliye caller isko await nahi karta.
  Future<void> _autoCacheInBackground(Song song, String streamUrl) async {
    try {
      final dir = await CacheService.instance.getAudioCacheDir();
      final filePath = p.join(dir.path, '${song.id}.m4a');
      final file = File(filePath);
      if (await file.exists()) return; // pehle se cached hai

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(streamUrl));
      final response = await request.close();
      final sink = file.openWrite();
      await response.pipe(sink);
      await sink.close();
      client.close();

      await CacheService.instance.cacheSong(song, filePath);

      // Agar ye song liked hai to protect flag turant laga do
      if (await LikeService.instance.isLiked(song.id)) {
        await CacheDB.instance.markProtected(song.id);
      }
    } catch (e) {
      // Cache fail hua to koi baat nahi — playback pe asar nahi padega
    }
  }
}
