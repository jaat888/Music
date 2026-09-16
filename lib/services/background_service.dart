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
      // BUG FIX (2026-09-16, v9): audio_service 0.18.19 me ab ek build-time
      // assert hai — `androidNotificationOngoing: true` sirf
      // `androidStopForegroundOnPause: true` ke saath allowed hai (varna
      // "will make no effect" throw hota hai), kyunki jab foreground
      // service active rehti hai (stopForegroundOnPause: false) to Android
      // khud hi notification ko ongoing/non-dismissable bana deta hai —
      // isliye androidNotificationOngoing ki yahan zaroorat hi nahi thi.
      // androidNotificationOngoing hata diya (default false), asli intent
      // (pause pe bhi foreground service + controls persist) neeche wale
      // androidStopForegroundOnPause: false se already poora hota hai.
      //
      // BUG FIX (2026-09-16, v8): pehle "true" tha — pause karte hi
      // foreground service demote ho jaati thi. MIUI jaise aggressive
      // OEMs par isse notification/control-center media card
      // controls-less (sirf title/artist/progress) ho jaata tha,
      // kabhi-kabhi poora card hi gayab. Ab pause pe bhi foreground
      // me rehta hai — controls hamesha dikhenge, jab tak user khud
      // stop() na kare (queue khatam / explicit stop).
      androidStopForegroundOnPause: false,
      preloadArtwork: true,
    ),
  );
}

class SurSathiAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer player = AudioPlayer();

  // BUG FIX (2026-09-16, v5): "latest request wins" token. User jab jaldi-
  // jaldi gaane badalta hai (ya bahut saare songs test karta hai), har tap
  // playWithRetry()/playFromFile() ko call karta hai — ye sab background
  // me PARALLEL chalte the, koi bhi cancel nahi hota tha. Jo bhi request
  // sabse aakhir me (kabhi bhi, kisi bhi order me) complete hoti thi, wahi
  // mediaItem/playbackState ko overwrite kar deti thi — chahe user tab tak
  // 3-4 aur gaane aage badh chuka ho. Isi wajah se: play/pause button
  // glitch (stale request ne abhi playing:true/false flip kar diya),
  // notification kabhi controls na dikhana (rapid state churn se
  // audio_service ka Android notification confuse ho jaata), aur agar
  // user bahut test kare to sab requests background me load hote rehte —
  // lag hota hai kyunki koi bhi cancel nahi hoti.
  //
  // Fix: har naya playWithRetry/playFromFile call apna unique token leta
  // hai (`++_playToken`). Har await ke baad check hota hai ki token abhi
  // bhi "latest" hai ki nahi — agar koi naya request beech me aa chuka hai
  // (matlab _playToken aage badh chuka hai), to ye purana request chup-
  // chaap return ho jaata hai, kuch bhi overwrite nahi karta.
  int _playToken = 0;

  // BUG FIX: pehle koi user-facing feedback nahi tha jab saare YouTube
  // clients fail ho jaate the (e.g. lambi "Full Album/Mix" compilation
  // videos, ya region/age-restricted videos jinka audio-only stream
  // resolve nahi hota). processingState `error` ho jaata tha, lekin
  // mini_player/full_player me sirf loading/buffering dekha jaata tha
  // isliye UI bas normal "play" button dikha deta tha 0:00/0:00 ke saath
  // — user ko lagta "kuch hua hi nahi". Ab `main.dart` isko set karta hai
  // taaki ek SnackBar dikha sake.
  void Function(String message)? onError;

  SurSathiAudioHandler() {
    // just_audio ke playback events ko audio_service ke playbackState me map karo
    player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace st) {
        // BUG FIX (Post-Batch-15 Fix #2): `player.setUrl(url)` khud kabhi
        // throw nahi karta jab URL "syntactically" theek ho — asli CDN
        // error (403/network drop/stream format issue) sirf ISI async
        // stream pe aata hai, kaafi der baad (setUrl() ke andar wale
        // try/catch se poori tarah bahar). Pehle yahan sirf
        // `processingState: error` set hota tha — koi `onError?.call(...)`
        // nahi tha, isliye `main.dart` ka global SnackBar kabhi nahi
        // dikhta tha is path se. Result: "URL resolve to ho gaya, setUrl()
        // bhi pass ho gaya" — lekin gaana chala hi nahi, aur user ko
        // koi feedback tak nahi milta tha (bilkul silent — na spinner na
        // error, bas 0:00/0:00 pe atka reh jaata).
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            playing: false,
          ),
        );
        final title = mediaItem.valueOrNull?.title;
        onError?.call(
          title != null
              ? '"$title" play karte waqt error aaya (stream drop ho gaya). Koi aur gaana try karein.'
              : 'Playback me error aaya. Koi aur gaana try karein.',
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
    _playToken++; // koi bhi pending stale resolve ab kuch overwrite nahi karega
    _skipDebounce?.cancel();
    await player.stop();
    await super.stop();
  }

  // BUG FIX (2026-09-16, v16, EXTENDED v20): "bahut baar tap karo (next ho
  // ya koi bhi gaana) to app crash ho jaata hai". Root cause: playback shuru
  // karne wale saare paths turant playWithRetry() -> YoutubeService.
  // getAudioUrl() shuru kar dete the, ismein NewPipeExtractor (WebView-based
  // JS solver) + youtube_explode_dart + Piped, teeno heavy network/native
  // calls hain. _playToken sirf ye rokta hai ki PURANA result final state ko
  // overwrite kare — lekin har tap ka poora resolve pipeline (WebView
  // spin-up sameet) fir bhi background me chalta rehta hai, chahe uska
  // result baad me discard ho jaaye. User jab jaldi-jaldi (next ho ya search/
  // home/kisi bhi list se alag-alag gaane) tap karta hai, kai saare in-flight
  // WebView/network extractions ek saath overlap ho jaate hain — MIUI jaise
  // kam-RAM/aggressive OEMs par ye native crash (OOM ya WebView instance
  // limit) trigger karta hai, sirf Flutter-side error nahi (isliye koi catch/
  // onError isko pakad nahi paata tha).
  // Fix (v20): debounce ab `playWithRetry()` ke andar hi centralized hai
  // (dekho neeche) — is se skip/previous, aur har screen ka seedha
  // `audioHandler.playWithRetry(song)` call, sab isi ek jagah se protect
  // hote hain. Yahan `_skipDebounce` field sirf declare hua hai taaki
  // `stop()` (aur playWithRetry khud) ek hi Timer share kar sakein.
  Timer? _skipDebounce;

  @override
  Future<void> skipToNext() async {
    final q = QueueService.instance;
    // BUG FIX (2026-09-16, v20): "gaana khatam hone ke baad crash/ajeeb
    // behavior" — agar repeat OFF hai aur ye QUEUE KA AAKHRI gaana hai,
    // `QueueService.next()` jaanbujhke currentIndex change NAHI karta
    // (dekho queue_service.dart ka apna comment: "currentIndex wahi
    // rehta hai, player ruk jayega") — matlab intent tha ki player bas
    // ruk jaaye. Lekin yahan neeche hamesha `_playCurrentFromQueue()` hi
    // call hota tha, chahe index badla ho ya nahi — jo isi (abhi-khatam)
    // gaane ko FIR SE resolve karke replay kar deta tha. Result: gaana
    // khatam → dobara wahi resolve+play → wo bhi khatam → phir wahi —
    // ek silent infinite "khatam→replay" loop, jisme har cycle apna
    // poora naya heavy resolve call (NewPipeExtractor) bhi karta tha.
    // Fix: pehle hi check kar lo ki ye "aakhri gaana, repeat off" wala
    // case hai ki nahi — agar hai, seedha `stop()` karo, replay mat karo.
    final wasLastWithNoRepeat =
        q.repeat == SurRepeatMode.off && q.currentIndex == q.queue.length - 1;
    q.next();
    if (wasLastWithNoRepeat) {
      await stop();
      return;
    }
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
  Future<void> playSong(Song song, String url) => _playSong(song, url, ++_playToken);

  Future<void> _playSong(Song song, String url, int token) async {
    if (token != _playToken) return; // ek naya request already aa chuka hai
    mediaItem.add(_toMediaItem(song));
    try {
      await player.setUrl(url);
      if (token != _playToken) return; // setUrl ke dauraan koi naya tap aa gaya
      await player.play();
      // Cache background me ho jaaye — playback ruke bina
      unawaited(_autoCacheInBackground(song, url));
    } catch (e) {
      if (token != _playToken) return;
      // URL kharab nikla — processing state error kar do, UI ko pata chal jaaye
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          playing: false,
        ),
      );
      onError?.call('"${song.title}" play nahi ho paya. Koi aur gaana try karein.');
    }
  }

  // Stream URL fetch karne me thoda flaky hota hai YouTube ka — 3 baar try karo
  //
  // BUG FIX: pehle mediaItem sirf playSong() ke andar set hota tha, jo tab
  // tak call hi nahi hota jab tak URL resolve na ho jaaye. Matlab tap karne
  // ke baad — jab tak YouTube ke 3 attempts x 5 clients try nahi ho jaate —
  // mini player hi screen pe nahi aata (mediaItem null rehta hai), koi
  // spinner nahi, koi feedback nahi. User ko lagta tha "kuch hua hi nahi /
  // app lag gaya", jabki background me actually kaam chal raha hota tha.
  // Ab yahan turant (URL fetch shuru hone se pehle) mediaItem + "loading"
  // playbackState broadcast karte hain taaki mini player/full player turant
  // dikhe aur spinner/loading state UI me nazar aaye.
  Future<void> playWithRetry(Song song) async {
    final token = ++_playToken;
    mediaItem.add(_toMediaItem(song));
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [MediaControl.stop],
        // BUG FIX (crash log 2026-09-16): `controls` yahan sirf 1 item
        // (`stop`, index 0) tak shrink kiya jaata hai, lekin
        // `androidCompactActionIndices` copyWith() me pichhli value
        // (`_broadcastState()` se aaya [0, 1, 3], normal playback ke
        // controls — previous/play-pause/stop/next — ke liye) carry
        // forward kar deta tha kyunki yahan explicitly overwrite nahi
        // kiya gaya tha. Notification compact-view index 1 aur 3 maangta
        // tha jabki sirf 1 control (index 0) tha — Android ka
        // `RemoteServiceException: setShowActionsInCompactView: action 1
        // out of bounds (max 0)` isi mismatch se aata hai, aur ye poore
        // app process ko turant crash kar deta hai (system-level
        // notification-inflation crash, Dart try/catch se bilkul bhi
        // pakda nahi ja sakta — matlab jab bhi koi naya gaana load hona
        // shuru hota (loading state) is line ke through guzarta, crash
        // ho jaata tha). Fix: `controls` jab bhi shrink/badle,
        // `androidCompactActionIndices` ko bhi USI list ke saath explicitly
        // match karo.
        androidCompactActionIndices: const [0],
        processingState: AudioProcessingState.loading,
        playing: false,
      ),
    );

    // BUG FIX (2026-09-16, v20): "koi aur gaana pe click karo to 1 sec
    // me crash" — pehle sirf skipToNext()/skipToPrevious() ko debounce
    // milta tha (dekho #47 upar). Lekin HAR screen (search, home, artist,
    // album, library, playlists, liked songs, live playlist) seedha
    // playWithRetry() call karti hai jab user kisi bhi song pe tap karta
    // hai — wahan koi debounce nahi tha. _playToken sirf STALE RESULT ko
    // overwrite hone se rokta hai, lekin har tap ka heavy resolve pipeline
    // (NewPipeExtractor WebView solver + youtube_explode_dart + Piped)
    // turant shuru ho jaata tha, chahe result discard hi kyun na ho jaaye.
    // Jab user jaldi-jaldi alag-alag gaano pe tap karta (ya ek se zyada
    // "next" jaisi rapid taps kahin se bhi aati), kai heavy WebView/native
    // extractions ek saath overlap ho jaate the — yahi asli crash tha (OOM/
    // WebView instance limit, native-side, isliye koi Dart catch/onError
    // isko pakad nahi paata tha) — bilkul #47 jaisa hi root cause, bas
    // trigger karne ka call-site alag tha. User ka "queue mismatch" wala
    // shak sahi direction me tha (do requests overlap ho rahi thi), bas
    // asli wajah queue data corruption nahi, balki overlapping native
    // resolve calls thi.
    // Fix: resolve pipeline (neeche wala poora retry-loop) ab turant shuru
    // nahi hota — ek chhoti 300ms debounce ke baad hi shuru hota hai, aur
    // agar is dauraan koi naya playWithRetry/skip aa jaaye (_playToken
    // aage badh jaaye), to ye purana debounced call chup-chaap cancel ho
    // jaata hai (koi extra heavy call nahi hoti). mediaItem + "loading"
    // state upar hi turant broadcast ho chuke hain, isliye UI (mini
    // player/full player) turant update dikhta hai — sirf asli network
    // resolve thoda delay hota hai jab tak taps settle na ho jaayein.
    final completer = Completer<void>();
    _skipDebounce?.cancel();
    _skipDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (token != _playToken) {
        completer.complete();
        return;
      }
      await _resolveAndPlay(song, token);
      completer.complete();
    });
    return completer.future;
  }

  Future<void> _resolveAndPlay(Song song, int token) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      // BUG FIX (2026-09-16, v5): agar is dauraan user ne koi aur gaana
      // tap kar diya (_playToken aage badh gaya), to ye purana attempt
      // chup-chaap ruk jaata hai — na error dikhata, na retry karta, na
      // kisi cheez ko overwrite karta.
      if (token != _playToken) return;

      // BUG FIX: pehle yahan koi timeout nahi tha, aur youtube_service.dart
      // ke andar bhi network calls unbounded the — agar koi request stall
      // ho jaaye to poora player hamesha ke liye "loading" pe atka reh
      // jaata tha (0:00/0:00, pause icon freeze), na koi error na kuch
      // play hota. Ab har attempt max 45s tak try karta hai, uske baad
      // fail maan ke agle attempt ya final error pe chala jaata hai.
      //
      // BUG FIX 2: pehle sirf song.id pass hota tha. song.title/artist
      // (jo humein already pata hai) YoutubeService ko diya hi nahi
      // jaata tha, isliye videoId-corrupt-hone-pe self-heal (dekho
      // youtube_service.dart _resolvePlayableVideoId) kabhi trigger hi
      // nahi hota tha yahan se — sirf standalone Termux test me hota
      // tha. Ab title/author bhi pass karte hain taaki asli app me bhi
      // wahi self-heal chale jo Termux test me pass hota tha.
      String? url;
      try {
        url = await YoutubeService.instance
            .getAudioUrl(song.id, title: song.title, author: song.artist)
            .timeout(const Duration(seconds: 45));
      } on TimeoutException {
        print('playWithRetry: attempt $attempt timed out after 45s');
        url = null;
      }
      if (token != _playToken) return; // resolve hone tak user aage badh chuka
      if (url != null) {
        await _playSong(song, url, token);
        return;
      }
      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    // Teeno attempts fail — error state (sirf agar ye ab bhi latest request hai)
    if (token != _playToken) return;
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
      ),
    );
    onError?.call(
      '"${song.title}" abhi available nahi hai (shayad bahut lambi ya '
      'restricted video hai). Koi aur gaana try karein.',
    );
  }

  // Local file se play karo — downloaded ya already-cached songs ke liye
  Future<void> playFromFile(Song song, String filePath) async {
    final token = ++_playToken;
    mediaItem.add(_toMediaItem(song.copyWith(filePath: filePath)));
    try {
      await player.setFilePath(filePath);
      if (token != _playToken) return; // dauraan koi naya tap aa gaya
      await player.play();
    } catch (e) {
      if (token != _playToken) return;
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          playing: false,
        ),
      );
      onError?.call('"${song.title}" file corrupt lag rahi hai ya delete ho gayi hai.');
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
      await playWithRetry(song);
    }
  }

  // NEW (2026-09-16): mini player + full player me "Retry" button ke liye —
  // jab playbackState.processingState == error ho jaaye (koi stream/file
  // resolve nahi hua), user isse tap karke wahi current song dobara try kar
  // sake, bina wapas queue/search me jaake dobara select kiye. Same source-
  // selection logic reuse karta hai jo _playCurrentFromQueue use karta hai
  // (currentSong abhi bhi wahi hai jo fail hua tha — sirf index change nahi
  // hota agar sirf retry chahiye).
  Future<void> retryCurrent() => _playCurrentFromQueue();

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
