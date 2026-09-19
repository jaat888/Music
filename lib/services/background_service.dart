// lib/services/background_service.dart
// SABSE ZAROORI FILE — actual playback yahi se hota hai. audio_service ke
// BaseAudioHandler ko implement karta hai taaki background play, notification
// controls, aur lock screen controls sab kaam karein.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/cache_db.dart';
import '../db/download_db.dart';
import '../db/play_history_db.dart';
import '../models/song.dart';
import 'app_logger.dart';
import 'cache_service.dart';
import 'chunked_audio_source.dart';
import 'download_queue_service.dart';
import 'equalizer_presets.dart';
import 'like_service.dart';
import 'local_media_resolver.dart';
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
      // BUG FIX (2026-09-16, v22): "notification me controls invisible
      // rehte hain, tap karne se kaam karta hai par dikhta nahi" — ye
      // `androidNotificationIcon` yahan kabhi set hi nahi kiya gaya tha,
      // isliye audio_service apna default `mipmap/ic_launcher` use kar
      // raha tha — jo app ka NORMAL full-color launcher icon hai. Android
      // status-bar/media-notification icons sirf ek flat alpha MASK ke
      // roobh me draw hote hain (koi real color allowed nahi) — ek
      // colored PNG/adaptive-icon diya jaaye to system usko silhouette
      // banane ki koshish karta hai aur zyaadatar OEMs (khaas kar MIUI/
      // Samsung dark theme) par result ek poori tarah invisible/blank
      // icon hota hai. Notification ka baaki structure (action buttons ki
      // tap-area/PendingIntents) bilkul theek register hote hain — isi
      // liye touch karne se kaam karta tha par kuch dikhta nahi tha.
      // Fix: apna khud ka single-color vector drawable banaya
      // (android/app/src/main/res/drawable/ic_notification.xml) aur use
      // yahan explicitly point kiya.
      //
      // BUG FIX (2026-09-17, recurrence): ye string yahan sirf DART side pe
      // hai — native Android side isse Resources.getIdentifier() se runtime
      // pe dhoondta hai, isliye koi bhi compiled R.drawable.ic_notification
      // reference kahin nahi banta. Iska matlab Android ka resource shrinker
      // (shrinkResources) ye drawable "unused" samajh ke APK se hata sakta
      // hai — bilkul yahi wajah thi jab ye crash dobara aaya. Ab
      // android/app/src/main/res/raw/keep.xml me tools:keep se explicitly
      // protect kiya hua hai, taaki ye drawable kabhi bhi strip na ho, chahe
      // future me koi minify/shrink setting on ho jaaye.
      androidNotificationIcon: 'drawable/ic_notification',
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
      // BUG FIX (notification art kabhi-kabhi khaali/blank): song.thumb
      // YouTube ka high-res thumbnail hai (kaafi bada ho sakta hai).
      // preloadArtwork: true isse download to karta hai, lekin bina
      // downscale hint ke bada image kai OEMs/Android versions par
      // Binder transaction limit se seedha silently fail ho jaata hai —
      // art bilkul nahi dikhta, koi error/crash bhi nahi (isliye pakadna
      // mushkil tha). Chhota fixed size dene se ye reliably render hota hai.
      artDownscaleWidth: 256,
      artDownscaleHeight: 256,
    ),
  );
}

// NEW (2026-09-17) — Formal playback state machine phases.
//
// Ek gaana select karne se lekar actually bajne tak (ya fail hone tak) ke
// poore lifecycle ko explicit states mein todte hain, taaki UI (mini
// player, full player, notification) ko HAMESHA pata ho ki abhi kya ho
// raha hai — generic "loading" ki jagah.
class _WarmUrl {
  final String url;
  final String format;
  final DateTime cachedAt;

  const _WarmUrl({
    required this.url,
    required this.format,
    required this.cachedAt,
  });
}

enum PlaybackPhase {
  idle, // kuch bhi resolve/play nahi ho raha
  resolving, // NewPipe/explode/Piped se stream URL dhoonda ja raha hai
  verifying, // mila hua URL playable hai ya nahi check ho raha hai
  buffering, // URL mil gaya, just_audio load/buffer kar raha hai
  playing,
  paused,
  retrying, // ek attempt fail hua, agla try ho raha hai
  error, // sab attempts fail — ab kuch bhi auto-retry nahi ho raha
}

class SurSathiAudioHandler extends BaseAudioHandler with SeekHandler {
  // PART 1 (Normalize Volume): Android-only loudness enhancer, AudioPlayer
  // ke saath ek AudioPipeline ke through attach hota hai. Ye "true" cross-
  // track loudness matching (ReplayGain-jaisa per-song analysis) NAHI hai
  // — just_audio/ExoPlayer me wo built-in nahi hai, aur us level ka kaam
  // (LUFS analysis per song) bahut zyada scope hai. Ye ek fixed target-gain
  // boost hai (quiet-mastered gaano ko thoda upar uthata hai) — settings
  // me "Normalize Volume" ON/OFF isi ko enable/disable karta hai. iOS pe
  // ye package hi kuch nahi karta (Android-specific effect), par is app
  // me sirf android/ folder hai isliye abhi wo concern nahi hai.
  final AndroidLoudnessEnhancer _loudnessEnhancer = AndroidLoudnessEnhancer();

  // PART 2 (Equalizer): same `AudioPipeline` me ek aur Android-native
  // effect — `AndroidEqualizer` (ExoPlayer ka built-in EQ, Bass Boost/
  // Vocal jaisi presets ko yahi asli DSP apply karta hai). Pehle
  // equalizer_screen.dart sirf ek UI mockup tha (SharedPreferences me
  // save hota tha, koi audio effect kabhi attach hi nahi hua tha) — ab
  // wahi preset/band values seedha isi effect pe jaate hain.
  final AndroidEqualizer _equalizer = AndroidEqualizer();

  late final AudioPlayer player = AudioPlayer(
    audioPipeline: AudioPipeline(
      androidAudioEffects: [_loudnessEnhancer, _equalizer],
    ),
  );

  static const String _kNormalizeVolumePref = 'setting_normalize_volume';
  static const String _kPlaybackSpeedPref = 'setting_playback_speed';
  static const String _kEqualizerSettingsPref = 'equalizer_settings';
  // Enhancer "on" hone par kitna extra gain — dB me nahi, just_audio ka
  // `setTargetGain` 0.0-1.0 range leta hai (0 = no boost). 0.5 ek maddham
  // (safe, distortion-free) boost hai — bahut zyada karne pe loud gaano
  // clip/distort kar sakte hain.
  static const double _normalizeTargetGain = 0.5;

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

  // BUG FIX (2026-09-18 — user report: "notification pe Play dabao to URL
  // dobara request hoti hai, loop ban jaata hai"): jab tak naya gaana
  // resolve/buffer/retry ho raha hai, `player` object abhi kisi
  // ADHOORI/transitional state me hota hai — kabhi purana source paused
  // pada hota hai (setUrl abhi hua hi nahi), kabhi `setUrl()`/
  // `setAudioSource()` khud abhi await pe hoti hai. Is poore window me
  // agar KAHIN SE BHI (notification/lock-screen/Bluetooth/full-player —
  // sab isi `play()` override se guzarte hain) `player.play()` dobara call
  // ho jaaye, do cheezein ho sakti hain: (a) purana (abhi bhi loaded)
  // source resume ho jaaye, ya (b) in-flight `setUrl()` ke saath race karke
  // just_audio ek spurious error `playbackEventStream`'s `onError` pe bhej
  // de — jise humara apna CDN-stream-drop-recovery code (`_handleStreamDrop`,
  // dekho upar) genuine drop samajh ke FRESH URL nikaal ke retry kar deta
  // hai. Agar user (ya koi bhi repeat-tap) isi loading window me dobara
  // Play dabaye, yahi cheez baar-baar hoti hai — isi wajah se "URL
  // dobara-dobara request hoti hai, loop ban jaata hai" jaisa dikhta hai.
  //
  // Fix: `_setPhase()` (neeche) is flag ko khud maintain karta hai — jab
  // bhi phase resolving/verifying/buffering/retrying in se kisi me ho,
  // `_resolving = true`; playing/paused/error/idle pe `false`. Is dauraan
  // `play()` ko yahan hi chup-chaap ignore kar dete hain — jo resolve
  // already chal raha hai wahi khud playing state pe le jayega.
  //
  // Ek chhoti additional window bhi hai: `playWithRetry()`/`playFromFile()`
  // shuru hote hi (purana gaana pause karne se pehle hi) turant
  // `_resolving = true` set karte hain — kyunki `_setPhase(resolving)`
  // khud thodi der baad (~300ms debounce ke baad) aata hai, us debounce
  // ke dauraan bhi (jab purana gaana already pause ho chuka hota hai)
  // Play dabana purane gaane ko resume kar sakta tha — ye bhi isi se cover
  // ho jaata hai.
  bool _resolving = false;

  // NEW (2026-09-17) — PlaybackPhase state machine.
  //
  // Upar wala `_playToken` mechanism sahi hai (cancellation ka asli
  // core — koi purana/stale request kabhi final state overwrite nahi
  // karta), lekin abhi tak sirf ek "cancellation guard" tha, koi
  // observable STATE nahi — UI (mini player/full player/notification)
  // ko pata hi nahi chalta tha ki abhi "resolve ho raha hai" ya "retry
  // ho raha hai" ya "URL verify ho raha hai" — sirf generic loading-
  // spinner ya kuch nahi dikhta tha.
  //
  // Ye woh well-known general pattern hai jo bade media apps (ExoPlayer
  // ka apna STATE_*, ya kisi bhi production audio-player ka) use karte
  // hain: ek FINITE set of phases, ek SINGLE source-of-truth notifier,
  // aur har state-transition wahi generation-token cancellation use
  // karta hai jo already yahan tha. (Note: ye hamesha-se-known/public
  // software-design pattern hai — Spotify/YT Music/Apple Music ka
  // apna EXACT internal code kisi ko bahar se nahi pata, hum unka code
  // copy nahi kar rahe, sirf wahi industry-standard architecture apna
  // rahe hain jo har achha media player use karta hai.)
  //
  // `_playToken` ab is class ke bahar `phase`/`phaseMessage` ke through
  // observable hai — mini_player.dart isse "Resolving...", "Retry
  // 2/3...", "Playback error" jaisa granular status dikha sakta hai,
  // generic spinner ki jagah.
  final ValueNotifier<PlaybackPhase> phase =
      ValueNotifier(PlaybackPhase.idle);
  final ValueNotifier<String?> phaseMessage = ValueNotifier(null);

  // v90: `just_audio.playing` is normally the best signal, but during an
  // ExoPlayer hand-off it can briefly emit false even though the new source
  // is already READY and its position is advancing. UI/notification code
  // must not turn that tiny state publication gap into a fake spinner.
  // REAL PLAYBACK LATCH (v92): once this play request genuinely starts,
  // keep that fact for this token. ExoPlayer may briefly publish playing=false
  // during a READY/BUFFERING hand-off; that must not turn a working Pause
  // button into a fake spinner or make Radio reject a valid candidate.
  int? _playbackStartedToken;

  bool get playbackStarted =>
      player.playing ||
      (_playbackStartedToken == _playToken && !_userPaused &&
          player.processingState != ProcessingState.idle &&
          player.processingState != ProcessingState.completed);

  // v106 — EK hi "audio effectively bajh raha hai" signal (UI icon AUR tap
  // action dono ke liye). Pehle Radio ka icon `playing || playbackStarted ||
  // (ready && position>250ms)` se decide karta tha jabki `_togglePlay()`
  // sirf `playbackStarted` dekhta tha — hand-off gap mein icon "Pause"
  // dikhata aur tap `play()` call ho jaata. Ab dono isi getter se.
  //
  // `_userPaused` guard ZAROORI hai: paused player bhi `ready` rehta hai aur
  // uski position >250ms hoti hai — bina is guard ke position-fallback
  // paused gaane ko bhi "playing" dikhata (icon Pause pe atka rehta).
  bool get effectivelyPlaying {
    if (playbackStarted) return true;
    if (_userPaused) return false;
    return player.processingState == ProcessingState.ready &&
        player.position > const Duration(milliseconds: 250);
  }

  // v106 — Radio recovery ke liye: CURRENT play request "genuinely start" hui
  // ya nahi, `playbackStarted` latch + position-advance fallback se (raw
  // `player.playing`/`playingStream.first` se nahi — wo hand-off gap mein
  // chhoti si der `false` publish kar sakte hain aur ek valid start ko
  // failed candidate bana dete the). Confirm hote hi latch set hota hai
  // (`_waitUntilPlaying` jaisa). `false` = timeout YA request superseded
  // (`_playToken` badal gaya).
  Future<bool> waitForEffectiveStart({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final token = _playToken;
    final baseline = player.position;
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (token != _playToken) return false;
      final advanced = !_userPaused &&
          player.processingState == ProcessingState.ready &&
          player.position > baseline + const Duration(milliseconds: 150);
      if (playbackStarted || advanced) {
        _playbackStartedToken = token;
        return true;
      }
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  void _setPhase(int token, PlaybackPhase p, [String? message]) {
    // Stale request kabhi phase overwrite na kare — wahi `_playToken`
    // guard jo pehle se poore file mein use hota hai.
    if (token != _playToken) return;
    phase.value = p;
    phaseMessage.value = message;

    // BUG FIX (2026-09-18): dekho `_resolving` field ka poora comment —
    // resolve "in-progress" phases (resolving/verifying/buffering/
    // retrying) me true, baaki (idle/playing/paused/error — sab
    // terminal/stable states) me false. `play()` isi flag se guard hota
    // hai.
    _resolving = p == PlaybackPhase.resolving ||
        p == PlaybackPhase.verifying ||
        p == PlaybackPhase.buffering ||
        p == PlaybackPhase.retrying;

    // NEW (Phase 2, 2026-09-17): notification/lock-screen bhi phase-aware
    // — resolving/retrying/buffering/error ke dauraan status message
    // dikhta hai, taaki sirf mini-player nahi, notification/lock-screen
    // bhi bataye ki kya ho raha hai.
    //
    // BUG FIX (2026-09-17, v66 — user report: "koi kami nahi honi
    // chahiye"): PEHLE ye status `MediaItem.artist` ko temporarily
    // OVERWRITE kar deta tha. Dikkat: `MediaItem.artist` hi wo field hai
    // jisse app ke andar HAR jagah "asli artist" reconstruct hota hai
    // (`_songFromMediaItem()` in full_player_screen.dart, radio-seed,
    // etc.) — us 1-2 second transient window mein agar koi bhi cheez
    // us waqt "asli artist" maangti, usse galti se "Resolving..." jaisa
    // status-text mil jaata, asli naam nahi. Chhota/rare tha, lekin galat
    // tha. FIX: `artist` field ab KABHI nahi chhua jaata (hamesha asli
    // artist) — status ab `album` field mein jaata hai (jo Song/MediaItem
    // mein waise bhi kabhi use nahi hota tha, khaali/unused tha) — isliye
    // ab koi bhi consumer jo `.artist` padhta hai use hamesha sahi/asli
    // value milti hai, chahe kabhi bhi padhe.
    final song = _activePlaybackSong;
    if (song == null) return;
    if (p == PlaybackPhase.playing || p == PlaybackPhase.paused) {
      mediaItem.add(_toMediaItem(song)); // status clear — album=null
    } else if (message != null) {
      mediaItem.add(_toMediaItem(song, statusOverride: message));
    }
  }

  // FIX: "next dabane par 10s lagta hai" — pehle next song ka poora
  // resolve (NewPipe/explode/Piped) sirf next tap hone ke BAAD shuru hota
  // tha. Ab current gaana play hote hi agla gaana background me chup-
  // chaap resolve karke yahan cache ho jaata hai — skipToNext() aate hi
  // seedha ye URL use hota hai (instant), koi naya network call nahi.
  // BUG FIX (2026-09-18 — dekho youtube_service.dart getAudioUrlAndFormat()
  // ka comment aur chunked_audio_source.dart ka "ATTEMPT #4" comment):
  // pehle sirf URL string cache hoti thi, format discard ho jaata tha —
  // isi wajah se chunked playback ko format pata hi nahi chalta tha aur
  // wo galat MIME-type guess kar leta tha. Ab dono saath cache hote hain.
  // URL warm-cache is intentionally short-lived. YouTube media URLs are
  // signed/ephemeral, so a URL that was resolved much earlier is not safe to
  // assume playable later. Warm URLs are a latency optimisation, not a
  // permanent credential/cache.
  static const Duration _warmUrlTtl = Duration(minutes: 5);
  static const int _warmUrlCacheLimit = 12;
  static const int _prefetchWindow = 3;

  final Map<String, _WarmUrl> _urlCache = {};
  final Set<String> _prefetchingIds = {};
  final Set<String> _prefetchQueuedIds = {};
  final List<Song> _prefetchQueue = <Song>[];
  bool _prefetchWorkerRunning = false;

  _WarmUrl? _freshWarmUrl(String id) {
    final value = _urlCache[id];
    if (value == null) return null;
    if (DateTime.now().difference(value.cachedAt) >= _warmUrlTtl) {
      _urlCache.remove(id);
      return null;
    }
    return value;
  }

  void _trimWarmUrlCache() {
    while (_urlCache.length > _warmUrlCacheLimit) {
      final oldest = _urlCache.entries
          .reduce((a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b)
          .key;
      _urlCache.remove(oldest);
    }
  }

  void _enqueuePrefetch(Song song) {
    if (_freshWarmUrl(song.id) != null ||
        _prefetchingIds.contains(song.id) ||
        _prefetchQueuedIds.contains(song.id)) {
      return;
    }
    _prefetchQueuedIds.add(song.id);
    _prefetchQueue.add(song);
    unawaited(_drainPrefetchQueue());
  }

  void _retainPrefetchQueue(Set<String> keepIds) {
    if (_prefetchQueue.isEmpty) return;
    _prefetchQueue.removeWhere((song) {
      final remove = !keepIds.contains(song.id);
      if (remove) _prefetchQueuedIds.remove(song.id);
      return remove;
    });
  }

  Future<void> _drainPrefetchQueue() async {
    if (_prefetchWorkerRunning) return;
    _prefetchWorkerRunning = true;
    try {
      while (_prefetchQueue.isNotEmpty) {
        final next = _prefetchQueue.removeAt(0);
        _prefetchQueuedIds.remove(next.id);
        if (_freshWarmUrl(next.id) != null ||
            _prefetchingIds.contains(next.id)) {
          continue;
        }
        _prefetchingIds.add(next.id);
        try {
          final already = await LocalMediaResolver.instance.getPath(next.id);
          if (already != null) continue;

          _WarmUrl? resolved;
          for (var attempt = 1; attempt <= 2; attempt++) {
            try {
              final value = await YoutubeService.instance
                  .getAudioUrlAndFormat(
                    next.id,
                    title: next.title,
                    author: next.artist,
                  )
                  .timeout(const Duration(seconds: 25));
              if (value != null) {
                resolved = _WarmUrl(
                  url: value.url,
                  format: value.format,
                  cachedAt: DateTime.now(),
                );
                break;
              }
            } on TimeoutException {
              AppLogger.instance.log(
                '[PREFETCH] "${next.title}" attempt $attempt timed out after 25s.',
              );
            } catch (e, st) {
              AppLogger.instance.logError(
                '[PREFETCH] "${next.title}" attempt $attempt failed.',
                e,
                st,
              );
            }
            if (attempt < 2) {
              await Future.delayed(const Duration(milliseconds: 700));
            }
          }
          if (resolved != null) {
            _urlCache[next.id] = resolved;
            _trimWarmUrlCache();
            AppLogger.instance.log(
              '[PREFETCH] READY — "${next.title}" warm URL cached.',
            );
          } else {
            AppLogger.instance.log(
              '[PREFETCH] FAILED — "${next.title}" foreground playback will resolve fresh.',
            );
          }
        } finally {
          _prefetchingIds.remove(next.id);
        }
      }
    } finally {
      _prefetchWorkerRunning = false;
      // A producer may have queued another item between the final while-check
      // and setting the worker flag false.
      if (_prefetchQueue.isNotEmpty) {
        unawaited(_drainPrefetchQueue());
      }
    }
  }

  void _prefetchNext() {
    // Dedicated RadioPlayerScreen owns its own upcoming list. QueueService can
    // therefore contain a stale/normal queue while Radio is active; do not
    // let the generic prefetch path prune or replace Radio's warm-up queue.
    if (_radioPlaybackOwned) return;
    final upcoming = QueueService.instance.upcoming;
    final ids = upcoming.take(_prefetchWindow).map((song) => song.id).toSet();
    _retainPrefetchQueue(ids);
    for (final next in upcoming.take(_prefetchWindow)) {
      _enqueuePrefetch(next);
    }
  }

  // BUG FIX: pehle koi user-facing feedback nahi tha jab saare YouTube
  // clients fail ho jaate the (e.g. lambi "Full Album/Mix" compilation
  // videos, ya region/age-restricted videos jinka audio-only stream
  // resolve nahi hota). processingState `error` ho jaata tha, lekin
  // mini_player/full_player me sirf loading/buffering dekha jaata tha
  // isliye UI bas normal "play" button dikha deta tha 0:00/0:00 ke saath
  // — user ko lagta "kuch hua hi nahi". Ab `main.dart` isko set karta hai
  // taaki ek SnackBar dikha sake.
  void Function(String message)? onError;

  // BUG FIX (2026-09-16, v21): "stream drop ho gaya" error 1 sec ke andar
  // hi aa jaata tha, koi retry nahi hota tha — jabki URL-resolve wala path
  // (playWithRetry/_resolveAndPlay) 3 attempts x 45s tak try karta hai.
  // Root cause: ye do bilkul alag failure points hain —
  //   1) getAudioUrl() FAIL ho (URL hi nahi mila)   -> retry hota tha
  //   2) getAudioUrl() PASS ho, setUrl()/play() PASS ho, lekin CDN stream
  //      thodi der baad (kabhi turant) drop kare (403 / format issue /
  //      network reset) -> ye sirf player.playbackEventStream ke async
  //      onError se pata chalta hai, aur yahan pehle SEEDHA final error
  //      dikha diya jaata tha, ek bhi retry ke bina.
  // Fix: (2) wale case me bhi ab fresh URL nikaal ke retry hota hai —
  // max 3 attempts, har attempt se pehle 1s ka chhota gap — total budget
  // ~30s tak (fresh resolve + retries), tabhi jaake final error aata hai.
  int _streamErrorRetries = 0;
  // BUG FIX (user report: "network jaata/switch hota hai to gaana ka time
  // hat jaata hai" — mid-song CDN drop ke baad gaana 0:00 se dobara shuru
  // ho jaata tha): jab bhi stream drop hota hai, uss waqt ka `player.
  // position` yahan capture karte hain — SIRF is drop-cycle ke PEHLE
  // attempt pe (neeche `_handleStreamDrop()` me `_streamErrorRetries == 0`
  // check dekho), kyunki uske baad `_playSong()` khud position 0 pe reset
  // kar deta hai (normal fresh-play guarantee — dekho `_playSong()` ka
  // apna comment) — agar har retry pe dobara capture karte to 0 hi capture
  // hota. `_streamDropSongId` isi position ko GALAT gaane pe lagne se
  // rokta hai — agar is beech user khud koi doosra gaana chala de
  // (skip/naya tap), wo ek bilkul NAYA `playWithRetry()` hai, uska apna
  // fresh-start (0 se) hona hi sahi hai.
  Duration? _streamDropResumePosition;
  String? _streamDropSongId;
  static const int _maxStreamErrorRetries = 3;
  // BUG FIX (v101 — user-identified: "Future.timeout() sirf caller ki
  // waiting timeout karta hai; underlying Future baad mein bhi complete ho
  // sakta hai — purana setUrl()/resolver background mein chalta reh sakta
  // hai aur naya retry uske upar aa sakta hai, rapid retries mein source
  // competition/race ban sakta hai"): bilkul sahi — `player.setUrl()`/
  // `setAudioSource()` par lagaya gaya `.timeout()` sirf Dart-side `await`
  // ko turant fail kar deta hai; just_audio/ExoPlayer ka andar-hi-andar
  // chal raha asli prepare-operation cancel NAHI hota, wo apni marzi se
  // baad mein bhi complete ho sakta hai. Stream-drop retries `_playToken`
  // REUSE karte hain (jaan-boojh kar — wahi ek playback-intent ka retry
  // hai, naya nahi), isliye purana `if (token != _playToken) return;`
  // guard is race ko pakad hi nahi sakta — dono attempts ka token same
  // hota hai. Fix: ek ALAG, sirf-isi-liye generation counter — har
  // setUrl/setAudioSource attempt se pehle increment hota hai; us attempt
  // ka await (chahe success ho, chahe timeout ke baad bhi kabhi "complete"
  // ho) khatam hone ke baad, agar generation aage badh chuka hai (matlab
  // ek naya retry beech mein shuru ho chuka), to ye purana/stale attempt
  // chup-chaap yahin ruk jaata hai — seek/play/state-update kuch bhi nahi
  // karta, chahe uska apna setUrl call "successful" hi kyun na dikhe.
  int _setUrlGeneration = 0;
  Future<Duration?>? _activeSetUrlOperation;

  // A timed-out just_audio prepare cannot be cancelled by Future.timeout().
  // Stop the shared player first, then give the interrupted prepare a short
  // chance to unwind before starting a replacement source.
  Future<void> _abortInFlightSetUrl() async {
    final active = _activeSetUrlOperation;
    if (active == null) return;
    try {
      await player.stop();
    } catch (_) {}
    try {
      await active.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
  // BUG FIX (2026-09-19 — user-identified race: "Global playbackEventStream
  // .onError current _playToken padhta hai. Error actually purane source ka
  // ho, lekin tab tak token naye song ka ho chuka ho, to old error new song
  // par retry trigger kar sakta hai. 700ms duplicate guard ye race fully
  // solve nahi karta, kyunki token bhi change ho sakta hai."):
  // Bilkul sahi pakda — `playbackEventStream` ek hi global stream hai (poore
  // `player` object ke liye, kisi specific source/attempt se tagged nahi).
  // Scenario: Song A baj raha hai, uske underlying HTTP connection ka drop
  // just_audio ko turant nahi, THODI DER BAAD pata chalta hai (network stack
  // ka apna internal delay — isi liye ye async `onError` alag se exist karta
  // hai, dekho neeche wala comment). Is BEECH agar user skip kar de (ya
  // auto-advance ho jaaye) aur Song B turant load+play ho jaaye, to jab tak
  // Song A ka STALE error aakhir me surface hota hai, `_playToken`/
  // `_activePlaybackSong` dono already Song B ke ho chuke hote hain.
  // `_handleStreamDrop()` (jo sirf CURRENT `_playToken`/current song padhta
  // hai) is stale error ko Song B ka GENUINE drop maan leta — Song B (jo
  // asal me bilkul theek chal raha tha) ke liye ek fresh URL retry cycle
  // shuru kar deta, jisse Song B beech mein hi restart/glitch ho jaata. Same
  // token hone ki wajah se `_lastStreamDropToken`/`_lastStreamDropAt` ka
  // 700ms dedup bhi isse nahi pakadta (wo sirf SAME token pe duplicate
  // signals ke liye hai) — token to yahan khud hi change ho chuka hota hai.
  //
  // just_audio ka `playbackEventStream` errors ko unke originating
  // source/attempt se tag nahi karta, isliye onError callback ke paas koi
  // seedha tareeka nahi hai ye confirm karne ka ki ye error CURRENT source
  // ka hai ya kisi abhi-abhi REPLACE kiye gaye purane source ka. Practical
  // mitigation (isi file ka established pattern — dekho `_setUrlGeneration`
  // upar, "sirf-isi-liye generation counter"): agar koi error ek fresh
  // `setUrl()`/`setAudioSource()` attempt shuru hone ke turant baad (chhoti
  // settle-window ke andar) aata hai, to wo ATTEMPT-STARTING attempt ka
  // genuine turant-fail nahi ho sakta (asli turant-fail `_playSong()`'s apne
  // try/catch se hi pakda jaata hai — dekho neeche ka comment, ye async
  // `onError` sirf "kaafi der baad" wale drops ke liye hai) — isliye is
  // window ke andar aaya koi bhi error, sabse zyada probability yahi hai ki
  // wo abhi-abhi REPLACE kiye gaye PURANE source ka delayed/stale signal hai.
  // Fix: har naye setUrl attempt ke start pe timestamp record karo; agar
  // onError is timestamp ke `_sourceSwitchSettleWindow` ke andar aaye, use
  // silently discard karo (current song/token ko chhuo tak mat) — asli
  // current-source drop ke liye ye chhota sa window kaafi safe hai, kyunki
  // genuine "kaafi der baad" wale drops per-definition is chhoti window se
  // bahar hi aate hain.
  DateTime? _lastSourceSwitchAt;
  static const Duration _sourceSwitchSettleWindow = Duration(milliseconds: 1800);
  // BUG FIX (v98 — user report + log evidence: "Laal Pari" gaane pe 38 se
  // zyada baar back-to-back "YT PLAY ATTEMPT" hue, ek hi minute ke andar,
  // resolve->fail->resolve->fail infinite loop): `_streamErrorRetries` har
  // 3-retry cycle ke END pe (chahe success ho ya "saare 3 retries fail,
  // final error") wapas 0 pe reset ho jaata tha. Agar us song ka underlying
  // network/CDN issue GENUINELY persistent tha (log me baar-baar "Connection
  // aborted"), to jab bhi agla error signal aata (async `playbackEventStream`
  // ka apna `onError` AUR `_playSong()` ka apna catch — dono independently
  // isi function ko call karte hain), counter fresh 0 pe milta aur ek
  // BILKUL NAYA 3-retry cycle shuru ho jaata — koi overall/cross-cycle cap
  // nahi tha. Isi wajah se ek hi gaana resolve->fail->resolve->fail
  // hamesha ke liye chalta reh sakta tha, kabhi terminal error pe ruk kar
  // agle gaane pe move hi nahi hota. Fix: jab ek gaana ek baar poori tarah
  // "give up" ho chuka ho, uska ID yahan record karo — agla koi bhi error
  // signal isi gaane ke liye aaye to naya cycle shuru mat karo, seedha
  // discard karo. Naya gaana actually successfully bajna shuru hote hi
  // (dekho _playSong() ka "playback successfully shuru" wala point) ye
  // clear ho jaata hai.
  String? _givenUpSongId;

  // BUG FIX (2026-09-18, v59 — "pause karo to 2-3 sec baad khud hi wapas
  // shuru se bajne lagta hai", full-screen aur notification dono se): Radio/
  // gaana YouTube ke signed CDN URL se seedha stream hota hai — koi bhi HTTP
  // connection ko pause() karke idle chhodo (chahe sirf 2-3 sec ke liye),
  // kai CDNs (Google Video included) us idle socket ko khud band/reset kar
  // dete hain. just_audio ye reset EK GENUINE "CDN drop" jaisa hi
  // `player.playbackEventStream`'s `onError` pe report karta hai — aur
  // neeche `_handleStreamDrop()` (jo asli mid-song network drops ke liye
  // bana tha) is "error" ko dekh ke fresh URL nikaal ke playback WAPAS SHURU
  // SE (`player.setUrl()` + `play()`) chala deta tha. Yahi wajah thi ki user
  // ka pause "kaam nahi karta" jaisa lagta tha — actually kaam to karta tha,
  // bas hamara apna hi stream-drop-recovery code use paused player ko
  // "recover" karke wapas bajne laga deta tha. Fix: jab tak user ne khud
  // pause() call kiya hai (is flag ke through), `onError` ko silently ignore
  // karo — koi retry, koi auto-resume nahi. Naya play() ya koi bhi fresh
  // playWithRetry()/playFromFile() start hote hi ye turant false ho jaata
  // hai, taaki asli (playing ke dauraan) stream-drop recovery bilkul pehle
  // jaisa hi kaam karta rahe.
  bool _userPaused = false;

  // BUG FIX (2026-09-19 — "gaana beech mein smooth chal raha tha, achanak
  // buffer pe hamesha ke liye atak gaya, koi error/retry nahi aaya"):
  // V94_FIXES.md khud isse ek known-gap maanti thi — "Mid-play buffering
  // stall ka watchdog nahi". ROOT CAUSE: `_handleStreamDrop()` (upar dekho)
  // sirf DO jagah se trigger hota hai — (1) `playbackEventStream`'s
  // `onError`, (2) `_playSong()`'s apna catch. Dono hi sirf tab fire hote
  // hain jab just_audio/CDN kisi throw-able error ke through fail hota
  // hai. Lekin real-world me ek "silent stall" bhi hota hai: connection
  // (Wi-Fi<->mobile-data switch, CDN half-open socket, ISP throttle) drop
  // ho jaata hai lekin koi exception kabhi throw hi nahi hoti — player bas
  // `ProcessingState.buffering` me fasa reh jaata hai, permanently, kyunki
  // wo ProcessingState.buffering se khud kabhi nikalta nahi (na `ready`
  // wapas, na `error`). Is case me na `onError` fire hota hai na `_playSong`
  // ka catch — poora stream-drop-recovery path (retry/resume) kabhi chalta
  // hi nahi, aur audio hamesha ke liye rukta reh jaata hai, silently, koi
  // spinner/error tak nahi (kyunki phase khud kabhi `error` set hi nahi
  // hota).
  //
  // Fix: ek chhota watchdog Timer, sirf tab active jab playback GENUINELY
  // shuru ho chuka ho (`_playbackStartedToken == _playToken` — initial
  // resolve/buffering ka normal window nahi) aur player `ready` ya `buffering`
  // state me ho. Timer position ko compare karta hai, isliye buffering event
  // na aaye tab bhi READY + no-progress wala silent stall pakda ja sake.
  // User pause/stop kare to watchdog disarm ho jata hai; real stall milne par
  // wahi tested `_handleStreamDrop()` retry/give-up/notify path reuse hota hai.
  static const Duration _stallWatchdogTimeout = Duration(seconds: 8);
  Timer? _stallWatchdogTimer;
  Duration _stallWatchdogPosition = Duration.zero;
  DateTime? _stallWatchdogPositionAt;

  void _armStallWatchdog(int token) {
    _stallWatchdogTimer?.cancel();
    _stallWatchdogPosition = player.position;
    _stallWatchdogPositionAt = DateTime.now();
    _stallWatchdogTimer = Timer(_stallWatchdogTimeout, () {
      _stallWatchdogTimer = null;
      if (token != _playToken) return;
      if (_userPaused) return;
      if (_playbackStartedToken != token) return;
      final state = player.processingState;
      if (state != ProcessingState.buffering &&
          state != ProcessingState.ready) return;
      final elapsed = _stallWatchdogPositionAt == null
          ? Duration.zero
          : DateTime.now().difference(_stallWatchdogPositionAt!);
      final advanced = player.position >
          _stallWatchdogPosition + const Duration(milliseconds: 250);
      if (advanced) {
        // A real position advance proves the stream is alive even when
        // processingState stayed READY instead of entering BUFFERING.
        _armStallWatchdog(token);
        return;
      }
      print('YT PLAYBACK STALL WATCHDOG: ${_stallWatchdogTimeout.inSeconds}s '
          'tak position advance nahi hua (state=$state, elapsed=${elapsed.inMilliseconds}ms) — '
          'silent CDN/network stall maan ke stream-drop recovery start kar rahe hain.');
      _handleStreamDrop();
    });
  }

  void _disarmStallWatchdog() {
    _stallWatchdogTimer?.cancel();
    _stallWatchdogTimer = null;
  }

  // PART 2 (Sleep timer — "Song khatam hone tak"): jab true ho, current
  // gaana khatam hote hi (ProcessingState.completed) agle gaane pe
  // skipToNext() karne ke bajaye bas pause() ho jaata hai. Ye flag khud
  // handler ke andar hi rehta hai (audioHandler global hai — kisi bhi
  // screen ke navigate/dispose hone se iska koi lena dena nahi), isliye
  // SleepTimerService (jo isko set/reset karta hai) ko is baare me
  // pehle se kuch janna zaroori nahi.
  bool sleepAtEndOfTrack = false;
  // SleepTimerService is callback ko set karta hai taaki jab yahan
  // end-of-track sleep fire ho, uska apna state/icon bhi turant "off"
  // reflect ho jaaye.
  void Function()? onSleepAtEndOfTrackFired;

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
        //
        // BUG FIX (2026-09-17): asli `e`/`st` yahan receive to hote the
        // lekin kabhi print/log nahi hote the — sirf discard. Ye exactly
        // wo case hai jahan "URL resolve hota hai, test bhi pass, phir
        // bhi gaana nahi chalta" — kyunki fail hi is silent stream se
        // ho raha hota hai, jo _handleStreamDrop() ke andar bhi kabhi
        // log nahi hota tha. Ab yahan turant print karte hain.
        // BUG FIX (2026-09-18, v59): dekho `_userPaused` field ka comment —
        // user ke apne pause() ke baad aane wala "drop" fake hota hai, use
        // real CDN drop maan ke resume/replay nahi karna hai.
        if (_userPaused) {
          print('YT PLAYBACK STREAM ERROR ignored — user ne khud pause kiya '
              'hua hai, auto-resume nahi karenge: $e');
          return;
        }
        // BUG FIX (2026-09-19): dekho `_lastSourceSwitchAt` ka poora comment
        // upar — abhi-abhi (settle-window ke andar) ek naya setUrl attempt
        // (naya gaana ya isi gaane ka retry) shuru hua hai. Ye error us NAYE
        // attempt ka turant-fail nahi ho sakta (wo `_playSong()`'s apne
        // try/catch se pakda jaata), isliye ye zyada-tar PURANE, abhi
        // replace kiye gaye source ka stale/delayed signal hai — current
        // (naye) token/song ke naam par retry trigger karna galat hoga.
        final sinceSwitch = _lastSourceSwitchAt == null
            ? null
            : DateTime.now().difference(_lastSourceSwitchAt!);
        if (sinceSwitch != null && sinceSwitch < _sourceSwitchSettleWindow) {
          print('YT PLAYBACK STREAM ERROR ignored — abhi-abhi '
              '(${sinceSwitch.inMilliseconds}ms pehle) naya source set hua '
              'hai, ye stale/purane-source ka delayed error lagta hai: $e');
          return;
        }
        print('YT PLAYBACK STREAM ERROR (CDN drop, setUrl pass hone ke '
            'baad): $e');
        _handleStreamDrop();
      },
    );

    // Player khud khatam ho jaye (song end) to agla song bajao — SIRF agar
    // "song khatam hone tak" sleep timer active nahi hai. Agar active hai,
    // to agle gaane pe skip karne ke bajaye yahin pause kar do (ye poore
    // "sleep timer" feature ka poora point hai — warna skipToNext() ke
    // baad naya gaana turant bajna shuru ho jaata, sleep kabhi hota hi
    // nahi).
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _disarmStallWatchdog();
        // BUG FIX (2026-09-19 — user-identified: "uncancelled timeout +
        // stale stream events + inconsistent playback signal"): dekho
        // `_setUrlGeneration` ka poora comment upar — `player.setUrl()`/
        // `setAudioSource()` par laga `.timeout()` sirf Dart-side `await`
        // ko fail karta hai, underlying native operation (abhi bhi wahi
        // SHARED `player` object pe) apni marzi se baad mein bhi chal/
        // complete ho sakta hai. Har doosri reactive jagah (onError,
        // _playSong ke continuations, stall watchdog ka arm-check) is file
        // mein hamesha `token`/`_playbackStartedToken` se guard hoti hai —
        // sirf yahi ek listener (auto-advance-on-completed) ab tak BINA
        // kisi staleness-check ke seedha `skipToNext()`/`pause()` chala
        // deta tha. Agar koi aisa timed-out/abandoned attempt (jiska
        // Dart-side await kabhi ka discard ho chuka hai) kabhi der se
        // native `completed` bhej de, ye listener use CURRENT gaane ka
        // genuine "song khatam hua" maan ke galat skip/pause kar sakta
        // tha — theek wahi "gana smooth chal raha tha, achanak skip/pause
        // ho gaya" jaisa residual symptom. Fix: sirf tabhi trust karo jab
        // CURRENT token ki playback genuinely confirm-start ho chuki ho
        // (`_playbackStartedToken == _playToken` — bilkul wahi signal jo
        // stall-watchdog arm-check bhi use karta hai) — warna ye zombie/
        // stale signal maan ke chup-chaap ignore karo.
        if (_playbackStartedToken != _playToken) {
          print('YT PLAYBACK: stale/zombie "completed" signal ignored — '
              'current token ki playback abhi confirm-start hi nahi hui '
              '(purana/abandoned attempt ka late native event lagta hai).');
          return;
        }
        if (_radioPlaybackOwned) return;
        if (sleepAtEndOfTrack) {
          sleepAtEndOfTrack = false;
          pause();
          onSleepAtEndOfTrackFired?.call();
        } else {
          skipToNext();
        }
        return;
      }
      // BUG FIX (2026-09-19, mid-play stall watchdog — dekho `_stallWatchdogTimer`
      // ka poora comment upar): sirf tab arm karo jab ye MID-PLAY buffering ho
      // (gaana already genuinely bajna shuru ho chuka tha isi token ke liye) —
      // initial resolve/buffering window (naya gaana load hote waqt) yahan
      // touch nahi karte, uske apne alag retry/timeout paths already hain
      // (playWithRetry/_playSong attempts), unhe duplicate-trigger karne se
      // bachna hai.
      if (_playbackStartedToken == _playToken && !_userPaused &&
          state == ProcessingState.buffering) {
        _armStallWatchdog(_playToken);
      } else if (_playbackStartedToken == _playToken && !_userPaused &&
          state == ProcessingState.ready && _stallWatchdogTimer == null) {
        _armStallWatchdog(_playToken);
      } else if (state == ProcessingState.completed || state == ProcessingState.idle) {
        _disarmStallWatchdog();
      }
    });

    // BUG FIX (v37 — "notification bar mein gaane ko time wale kabhi nahi
    // dikhte"): mediaItem.duration hamesha search-result se aaye
    // `song.duration` (YouTube Music API metadata — kaafi baar 0 ya galat)
    // pe fix ho jaata tha, aur stream/file load hone ke baad ASLI duration
    // (`player.duration`) se kabhi update nahi hota tha. Notification/lock-
    // screen ka seekbar aur "0:00 / 3:45" jaisa total-time text isi
    // mediaItem.duration se aata hai — 0 rehne pe wahan time hamesha
    // khaali/0:00 hi dikhta tha. Fix: just_audio ka apna durationStream
    // sunte hain — jaise hi asli duration pata chale (URL/file load hote
    // hi), current mediaItem ko usi real duration se turant update kar do.
    player.durationStream.listen((d) {
      if (d == null) return;
      final current = mediaItem.value;
      if (current == null || current.duration == d) return;
      mediaItem.add(current.copyWith(duration: d));
    });

    // PART 1: pehli baar handler ban rahi hai — pichhli baar save kiya
    // hua playback speed aur normalize-volume state wapas apply karo
    // (varna har app restart pe speed 1.0x aur normalize OFF pe reset ho
    // jaata, chahe user ne pehle kuch aur set kiya ho).
    _restoreSavedAudioSettings();
  }

  Future<void> _restoreSavedAudioSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble(_kPlaybackSpeedPref) ?? 1.0;
      final savedNormalize = prefs.getBool(_kNormalizeVolumePref) ?? false;
      await player.setSpeed(savedSpeed);
      await _loudnessEnhancer.setEnabled(savedNormalize);
      if (savedNormalize) {
        await _loudnessEnhancer.setTargetGain(_normalizeTargetGain);
      }
    } catch (e) {
      // Effect/pipeline kisi purane OEM pe available na ho to bhi normal
      // playback (bina speed/normalize restore ke) chalna chahiye — crash
      // nahi hona chahiye.
      print('BG: saved speed/normalize restore fail hua (non-fatal): $e');
    }

    // PART 2 (Equalizer): equalizer_screen.dart isi 'equalizer_settings'
    // key me save karta hai — app restart pe wapas apply karo, warna har
    // baar EQ "Flat"/off pe reset ho jaata chahe user ne Bass/Vocal preset
    // choose kiya ho.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kEqualizerSettingsPref);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final enabled = data['enabled'] as bool? ?? true;
        await _equalizer.setEnabled(enabled);
        final rawBands = (data['bands'] as List?)?.cast<num>();
        if (rawBands != null && rawBands.length == kEqualizerBandFreqs.length) {
          await setEqualizerBands(rawBands.map((e) => e.toDouble()).toList());
        }
      }
    } catch (e) {
      print('BG: saved equalizer restore fail hua (non-fatal): $e');
    }
  }

  // ---------------- PART 2: Equalizer ----------------
  Future<void> setEqualizerEnabled(bool enabled) async {
    try {
      await _equalizer.setEnabled(enabled);
    } catch (e) {
      print('BG: equalizer enable/disable fail (non-fatal): $e');
    }
  }

  // `uiGains`: 10 values (-12..+12 dB), `kEqualizerBandFreqs` ke same order
  // me. Real Android device ka EQ apna hi fixed band-count/frequencies
  // expose karta hai (aam taur pe 5-6 bands, hardware/driver ke hisaab se
  // alag hota hai) — isliye seedha index-se-index map nahi ho sakta. Har
  // real band ke liye uski `centerFrequency` ke aas-paas wale 2 UI points
  // se (log-frequency scale pe, jaisa insaan pitch sunta hai) gain
  // interpolate karke nikalte hain, phir us band ki apni allowed
  // [lowerGainDb, upperGainDb] range me clamp karte hain.
  Future<void> setEqualizerBands(List<double> uiGains) async {
    if (uiGains.length != kEqualizerBandFreqs.length) return;
    try {
      final params = await _equalizer.parameters;
      for (final band in params.bands) {
        final target = _interpolatedGainDb(uiGains, band.centerFrequency);
        // BUG FIX (build break): `AndroidEqualizerBand` khud lowerGainDb/
        // upperGainDb expose nahi karta — allowed dB range poori equalizer
        // (`params`) pe hoti hai, har band pe alag nahi. `num.clamp()` bhi
        // `num` deta hai, `double` nahi — `setGain()` ko double chahiye,
        // isliye `.toDouble()`.
        final clamped = target
            .clamp(params.minDecibels, params.maxDecibels)
            .toDouble();
        await band.setGain(clamped);
      }
    } catch (e) {
      // Kisi OEM/emulator pe AndroidEqualizer available na ho to bhi
      // normal playback chalte rehna chahiye — sirf EQ apply nahi hoga.
      print('BG: equalizer band gains apply fail (non-fatal): $e');
    }
  }

  double _interpolatedGainDb(List<double> uiGains, double targetFreqHz) {
    final freqs = kEqualizerBandFreqs;
    if (targetFreqHz <= freqs.first) return uiGains.first;
    if (targetFreqHz >= freqs.last) return uiGains.last;
    for (var i = 0; i < freqs.length - 1; i++) {
      final f0 = freqs[i].toDouble();
      final f1 = freqs[i + 1].toDouble();
      if (targetFreqHz >= f0 && targetFreqHz <= f1) {
        final logF0 = math.log(f0);
        final logF1 = math.log(f1);
        final logT = math.log(targetFreqHz);
        final t = (logF1 == logF0) ? 0.0 : (logT - logF0) / (logF1 - logF0);
        return uiGains[i] + (uiGains[i + 1] - uiGains[i]) * t;
      }
    }
    return 0;
  }

  // ---------------- PART 1: Playback speed (0.5x–2x) ----------------
  @override
  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 2.0);
    await player.setSpeed(clamped);
    playbackState.add(playbackState.value.copyWith(speed: clamped));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kPlaybackSpeedPref, clamped);
    } catch (_) {
      // Persist fail ho to bhi is session ke liye speed already apply ho
      // chuki hai — sirf agli app-open pe wapas 1.0x pe reset hoga.
    }
  }

  double get currentSpeed => player.speed;

  // ---------------- PART 1: Normalize Volume ----------------
  // Settings screen ka "Normalize Volume" switch isko call karta hai.
  Future<void> setNormalizeVolume(bool enabled) async {
    try {
      await _loudnessEnhancer.setEnabled(enabled);
      if (enabled) {
        await _loudnessEnhancer.setTargetGain(_normalizeTargetGain);
      }
    } catch (e) {
      print('BG: normalize volume toggle fail (non-fatal): $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNormalizeVolumePref, enabled);
    } catch (_) {}
  }

  // Actual CDN stream-drop handler — ab yahan bhi retry hota hai (pehle
  // seedha final error dikha deta tha, 0 retries).
  // FIX (v94): EK hi asli failure ke liye do signal aate the — (1) player ka
  // playbackEventStream `onError` aur (2) `_playSong()` ka apna catch — dono
  // ~10-100ms ke andar `_handleStreamDrop()` bulate the. Result: ek error 2 retry
  // gin leta tha (real log: "retry 1/3" aur "retry 2/3" 9ms ke gap pe) aur do
  // parallel retry-chains ek dusre ka setUrl cut karti thi ("Source error"),
  // isliye 3 retries jaldi khatam ho ke ~10 sec ka atkna hota tha.
  // Ab same token ke liye 700ms ke andar dobara aaya call duplicate maana jaata hai.
  DateTime? _lastStreamDropAt;
  int? _lastStreamDropToken;

  void _handleStreamDrop() {
    final token = _playToken;
    final nowTs = DateTime.now();
    if (_lastStreamDropToken == token &&
        _lastStreamDropAt != null &&
        nowTs.difference(_lastStreamDropAt!) <
            const Duration(milliseconds: 700)) {
      print('YT STREAM DROP: duplicate signal (same failure, <700ms) — ignore kiya.');
      return;
    }
    _lastStreamDropToken = token;
    _lastStreamDropAt = nowTs;
    final song = _activePlaybackSong ?? QueueService.instance.currentSong;

    // BUG FIX (v98): dekho `_givenUpSongId` ka comment upar — isi gaane ke
    // liye pehle hi ek poora cycle "final error" tak ja chuka hai, ek naya
    // cycle shuru mat karo (infinite loop yahi tha).
    if (song != null && _givenUpSongId == song.id) {
      print('YT STREAM DROP: "${song.title}" already given up — naya cycle shuru nahi karenge.');
      return;
    }

    if (song != null && _streamErrorRetries == 0) {
      // Ye pehla drop hai is cycle ka — `player.position` abhi bhi asli
      // "gaana yahan tak baja tha" wali value hai, isse aage kisi bhi
      // retry/seek(0) se pehle capture kar lo.
      _streamDropResumePosition = player.position;
      _streamDropSongId = song.id;
    }
    if (song != null && _streamErrorRetries < _maxStreamErrorRetries) {
      _streamErrorRetries++;
      print('YT STREAM DROP: "${song.title}" — retry ${_streamErrorRetries}/'
          '$_maxStreamErrorRetries (fresh URL nikaal ke).');
      // Loading state dikhao — user ko "kuch hua hi nahi" na lage jab
      // background me retry chal raha ho.
      final alreadyStarted =
          _playbackStartedToken == token && !_userPaused;
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.loading,
          playing: alreadyStarted,
        ),
      );
      // BUG FIX (2026-09-18 — user report: "buffer beech mein hi stuck ho
      // jaata hai, update nahi hota"): ROOT CAUSE mila — ye poora
      // stream-drop retry path sirf `playbackState` (notification/OS-facing)
      // update karta tha, `phase`/`phaseMessage` (jo full player/Radio
      // screen ka "Buffering.../Resolving..." subtitle text drive karta
      // hai) ko YAHAN KABHI chua hi nahi jaata tha. Matlab agar drop se
      // theek pehle screen "Buffering..." dikha rahi thi, wahi text poore
      // retry-cycle (fresh URL fetch + re-play) ke dauraan hamesha ke liye
      // frozen reh jaata — chahe background mein retry chal bhi raha ho.
      // Ab yahan explicit `retrying` phase set karte hain taaki text turant
      // update ho.
      _setPhase(token, PlaybackPhase.retrying,
          'Stream drop — retry $_streamErrorRetries/$_maxStreamErrorRetries...');
      unawaited(_retryAfterStreamDrop(song, token));
      return;
    }

    // Retries khatam ho gaye (ya current song hi pata nahi) — ab final error
    print('YT STREAM DROP: "${song?.title}" — saare $_maxStreamErrorRetries '
        'retries fail, final error.');
    _streamErrorRetries = 0;
    // BUG FIX (v98): ab is gaane ko "given up" mark kar do — dekho
    // `_givenUpSongId` ka comment. Isse agla koi bhi (delayed/duplicate)
    // error signal isi gaane ke liye naya cycle shuru nahi karega.
    if (song != null) _givenUpSongId = song.id;
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
      ),
    );
    // BUG FIX (dekho upar wala comment) — final failure pe bhi `phase` ko
    // explicitly `error` set karo, warna text yahan bhi "Buffering..."/
    // "Retrying..." pe hamesha ke liye atka reh jaata, chahe playback
    // actually poori tarah ruk chuka ho.
    _setPhase(token, PlaybackPhase.error, 'Playback me error aaya');
    if (song != null) {
      _notifyPlaybackError(song);
    } else {
      onError?.call('Playback me error aaya. Koi aur gaana try karein.');
    }
  }

  Future<void> _retryAfterStreamDrop(Song song, int token) async {
    // Chhota gap taaki turant-turant CDN ko dobara na maare, network/CDN
    // ko thoda "settle" hone ka time mile.
    await Future.delayed(const Duration(seconds: 1));
    if (token != _playToken) return; // is dauraan user aage badh gaya

    // BUG FIX (dekho _handleStreamDrop() ka comment) — fresh URL fetch
    // shuru hote hi phase ko turant "resolving" pe le aao, taaki text
    // yahan bhi live update dikhe (constant "retry N/3..." pe frozen na
    // rahe jab tak naya URL na mil jaaye).
    _setPhase(token, PlaybackPhase.resolving, 'Naya stream dhoonda ja raha hai...');

    String? url;
    try {
      // getAudioUrl() koi purana cached URL nahi deta — har call pe fresh
      // resolve karta hai (naya signed URL), isliye same-CDN-drop dobara
      // hone ka chance kam ho jaata hai.
      url = await YoutubeService.instance
          .getAudioUrl(song.id, title: song.title, author: song.artist)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      url = null;
    }
    if (token != _playToken) return;

    if (url == null) {
      // Fresh URL bhi nahi mila — same handler dobara call karo, ye
      // apna retry-counter khud check karega (attempt 2, 3, ya final error).
      _handleStreamDrop();
      return;
    }

    // _streamErrorRetries pehle se hi ++ ho chuka hai _handleStreamDrop() me
    // (attempt 1/2/3) — usi count se header-strategy alternate karo (dekho
    // `_useHeadersForAttempt` ka comment, Attempt #5).
    await _playSong(
      song,
      url,
      token,
      useHeaders: _useHeadersForAttempt(_streamErrorRetries),
      resumeAt:
          _streamDropSongId == song.id ? _streamDropResumePosition : null,
    );
  }

  // ---------------- State broadcast ----------------

  // BUG FIX (user request, 2026-09-18 — "Notification kaise aa rahe the sab
  // kuch log ho"): `_broadcastState` har playback event (position tick,
  // buffering %, waghera) pe fire hota hai — HAR baar poora log likhna
  // file ko seconds me hi flood kar deta (2MB cap turant hit ho jaata,
  // asli useful log purana ho ke trim ho jaata). Isliye sirf TRANSITIONS
  // (playing flip, ya processingState badle) log hote hain — wahi
  // notification ka "kya dikh raha hai" actually badalta hai jab.
  bool? _lastLoggedPlaying;
  AudioProcessingState? _lastLoggedProcessingState;

  void _broadcastState(PlaybackEvent event) {
    final playing = playbackStarted;
    final processingState = const {
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[player.processingState]!;

    // PHASE SELF-HEAL (v81): just_audio is the authoritative playback
    // signal. In a Radio transition an older async resolve could leave the
    // custom phase at "buffering" even though ExoPlayer was already READY
    // and PLAYING. That produced the exact UI symptom: audio/progress moving
    // while Radio subtitle still said "Buffering...". Only promote the phase
    // when the player is genuinely READY+PLAYING; never hide a real loading
    // or buffering state.
    if (playing && player.processingState == ProcessingState.ready &&
        _activePlaybackSong != null &&
        (phase.value == PlaybackPhase.resolving ||
            phase.value == PlaybackPhase.verifying ||
            phase.value == PlaybackPhase.buffering ||
            phase.value == PlaybackPhase.retrying)) {
      _setPhase(_playToken, PlaybackPhase.playing);
    }

    if (playing != _lastLoggedPlaying ||
        processingState != _lastLoggedProcessingState) {
      AppLogger.instance.log(
        '[NOTIF] state -> playing=$playing, processingState=$processingState, '
        'controls=[prev, ${playing ? "pause" : "play"}, stop, next], '
        'compactIndices=[0,1,3], position=${player.position.inMilliseconds}ms',
      );
      _lastLoggedPlaying = playing;
      _lastLoggedProcessingState = processingState;
    }

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
        processingState: processingState,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: event.bufferedPosition,
        speed: player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }

  // ---------------- Base controls ----------------
  //
  // BUG FIX (user request, 2026-09-18 — "detailed log chahiye, kaunsa button
  // dabaya kab, kya response mila, notification kaise aa rahi thi"):
  // in sab methods (play/pause/seek/stop/skipToNext/skipToPrevious/
  // setShuffleMode/setRepeatMode) ko audio_service BOTH full-player/mini-
  // player ke UI buttons SE, AUR notification/lock-screen ke media
  // controls SE — dono jagah se seedha call karta hai (ek hi shared
  // handler, source jo bhi ho). Isliye yahan ek jagah "[CTL] <action>
  // called — before: ... / after: ..." jaisa log lagane se "us waqt kaunsa
  // button, kaisa response de raha tha" (UI ho ya notification, dono)
  // automatically cover ho jaata hai — har button ke liye alag se instrument
  // karne ki zaroorat nahi.
  void _logCtl(String action, [String? extra]) {
    AppLogger.instance.log(
      '[CTL] $action'
      '${extra != null ? " ($extra)" : ""}'
      ' — playing=${player.playing}, processingState=${player.processingState}, '
      'phase=${phase.value}, radioOwned=$_radioPlaybackOwned',
    );
  }

  Future<bool> _waitUntilPlaying({Duration timeout = const Duration(seconds: 6)}) async {
    final token = _playToken;
    final startedAt = player.position;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (player.playing) {
        _playbackStartedToken = token;
        AppLogger.instance.log('[PLAY] playback-start confirmed by player.playing=true — token=$token');
        return true;
      }
      if (token == _playToken &&
          player.processingState == ProcessingState.ready &&
          player.position > startedAt + const Duration(milliseconds: 150)) {
        _playbackStartedToken = token;
        AppLogger.instance.log('[PLAY] playback-start confirmed by position advance — position=${player.position.inMilliseconds}ms');
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (player.playing) {
      _playbackStartedToken = token;
      return true;
    }
    return false;
  }

  @override
  Future<void> play() {
    _logCtl('play() called');
    // BUG FIX (2026-09-18 — dekho `_resolving` field ka poora comment):
    // resolve/buffer/retry in-progress ho to play() ko yahin chup-chaap
    // ignore karo — warna purana source resume ho sakta hai ya
    // spurious-error se ek fresh URL-request loop trigger ho sakta hai.
    if (_resolving) {
      _logCtl('play() IGNORED — resolve already in-progress (phase=${phase.value})');
      return Future.value();
    }
    // BUG FIX (2026-09-18, v59): resume ke saath hi "user paused" flag
    // saaf karo — is se agla genuine stream drop (agar aaye) fir se normal
    // tarike se retry/recover hoga.
    _userPaused = false;
    // BUG FIX (2026-09-18 — real-device log: "Buffering..." hamesha ke liye
    // stuck, audio khud bilkul theek baj raha tha): pehle yahan SIRF
    // `paused -> playing` handle hota tha. Lekin `stop()` (neeche dekho)
    // `phase` ko kabhi touch nahi karta tha — agar `stop()` kisi BEECH-KE
    // resolve ke dauraan aa jaata (jaise Radio screen `dispose()` se, jab
    // user Radio se bahar aata theek us waqt jab naya gaana `buffering`
    // phase me tha), phase wahi FROZEN reh jaata (`buffering`/`resolving`/
    // `retrying`/`error`) — aur ye purana `paused`-only guard us frozen
    // state ko kabhi clear nahi karta tha jab user dobara Play dabata
    // (kyunki ye SIRF resume hai, naya resolve nahi — naya resolve hamesha
    // `playWithRetry()`/`_resolveAndPlay()` se aata hai, jo khud phase set
    // karte hain, is path se nahi). Result: audio perfectly play hota
    // rehta (`playing=true`, `processingState=ready`), lekin subtitle text
    // hamesha "Buffering..." dikhata rehta jab tak koi bilkul naya
    // song-change na ho jaaye. Fix: jab bhi resume genuinely successful ho
    // (neeche `player.play()` error nahi deta), phase ko unconditionally
    // `playing` kar do — sirf `paused` check hata diya, taaki koi bhi
    // stuck-frozen state (chahe kaise bhi aayi ho) hamesha clear ho jaaye.
    // FIX (v94): just_audio ka `player.play()` Future tab tak complete NAHI hota
    // jab tak playback pause/stop/complete na ho. Purana `.then(...)` isliye
    // phase ko `playing` TAB set karta tha jab user PAUSE dabata (log: `pause()
    // DONE — playing=false, phase=playing`), ya skip pe `stop()` ke waqt naye gaane
    // ka phase galat overwrite ho jaata tha. Ab resume hote hi (source ready ho to)
    // turant phase `playing` karte hain, aur play() ka Future playback-end tak
    // caller ko latkata nahi.
    final token = _playToken;
    final playFuture = player.play();
    if (player.processingState == ProcessingState.ready) {
      // Resume path me pause() ne latch clear kiya hota hai. READY state me
      // play command accept hote hi isi token ko active mark karo, warna
      // mid-play stall watchdog resume ke baad kabhi arm nahi hoga.
      _playbackStartedToken = token;
      _armStallWatchdog(token);
      if (phase.value != PlaybackPhase.playing) {
        _setPhase(token, PlaybackPhase.playing);
      }
    }
    _logCtl('play() DONE');
    unawaited(playFuture.catchError((Object e) {
      print('BG: player.play() error (non-fatal): $e');
    }));
    return Future.value();
  }

  @override
  Future<void> pause() {
    _logCtl('pause() called');
    _playbackStartedToken = null;
    // BUG FIX (2026-09-18, v59): full-screen ka pause button ho ya
    // notification/lock-screen ka — dono isi handler se guzarte hain, is
    // liye ek hi jagah flag set karne se dono cases cover ho jaate hain.
    _userPaused = true;
    // Mid-play stall watchdog bhi disarm karo — user ne khud pause kiya hai
    // jabki gaana buffering me ho sakta hai, isko stream-drop nahi maanna.
    _disarmStallWatchdog();
    // BUG FIX (2026-09-18): dekho play()/stop() ka comment — yahi symmetric
    // gap tha. Pehle sirf `playing -> paused` handle hota tha; agar phase
    // kisi frozen state (buffering/resolving/retrying/error) me atka ho aur
    // user Pause dabaye, ye guard silently kuch nahi karta tha — audio
    // genuinely pause ho jaata (`player.pause()` khud unconditional hai),
    // lekin subtitle purani frozen state hi dikhata rehta.
    if (phase.value != PlaybackPhase.paused) {
      _setPhase(_playToken, PlaybackPhase.paused);
    }
    return player.pause().then((_) => _logCtl('pause() DONE'));
  }

  @override
  Future<void> seek(Duration position) {
    // BUG FIX (seekbar-loading-guard, v3 — user ne log dobara dikhaya):
    // v2 ka `phase.value != playing && != paused` check TOO STRICT nikla
    // — same log mein aise legit seeks bhi hain jahan gaana GENUINELY
    // (playing=true, processingState=ready) baj raha tha lekin `phase`
    // khud `idle` par ATKA tha (queue khatam hone ke baad wale ek alag,
    // is fix ke scope se bahar wale flow mein — kahin `_setPhase()` call
    // hi nahi hota) — us check se ye BILKUL THEEK seeks bhi block ho
    // jaate (false positive), naya bug create kar dete.
    //
    // Sahi signal jo already maujood hai: `_resolving` (upar dekho,
    // `_setPhase()` khud maintain karta hai) — SIRF resolving/verifying/
    // buffering/retrying (matlab "naya URL abhi tak player ko mila hi
    // nahi") mein true hota hai, aur exactly wahi window hai jisme seek
    // genuinely galat/no-op hai (log line: `seek() called ... processing
    // State=ready [STALE, purane gaane ka], phase=resolving`). Us upar
    // wale "phase=idle par atka" flow mein `_resolving` kabhi true hua
    // hi nahi tha (kyunki `_setPhase()` kabhi call hi nahi hua), isliye
    // wahan false-positive nahi aata.
    final blocked =
        _resolving || player.processingState == ProcessingState.loading;
    if (blocked) {
      _logCtl(
        'seek() IGNORED — abhi resolve/load ho raha hai (resolving=$_resolving, processingState=${player.processingState}), position:',
        '${position.inMilliseconds}ms',
      );
      return Future.value();
    }
    _logCtl('seek() called', 'to ${position.inMilliseconds}ms');
    return player.seek(position);
  }

  @override
  Future<void> stop() async {
    _logCtl('stop() called');
    _playToken++; // koi bhi pending stale resolve ab kuch overwrite nahi karega
    _setUrlGeneration++;
    _playbackStartedToken = null;
    _lastSourceSwitchAt = DateTime.now();
    await _abortInFlightSetUrl();
    // BUG FIX (2026-09-19): `stop()` sirf `_playToken` bump karta tha,
    // `_userPaused` ko kabhi set nahi karta tha (dekho `_userPaused` field
    // ka poora comment upar — `onError` handler isi flag se decide karta
    // hai ki late/delayed CDN error ko real drop maan ke retry kare ya
    // ignore). Race: `stop()` ke turant baad agar player.stop() se pehle
    // ya uske dauraan koi late `onError` isi (abhi-abhi bumped) naye token
    // ke context mein aa jaaye, `_userPaused` false hone ki wajah se woh
    // real stream-drop maan liya jaata — `_handleStreamDrop()` apna 1-sec-
    // delay retry schedule kar deta (token abhi tak match karta hai kyunki
    // beech mein kuch aur bump nahi hua), aur kuch der baad audio khud-ba-
    // khud wapas bajne lagta — "Stop kiya, thodi der baad gaana khud
    // resume ho gaya" jaisa bug. Fix: `pause()` ki tarah `stop()` bhi ek
    // explicit user action hai, isliye yahan bhi flag set karo taaki
    // `onError` aisa koi bhi late/stray error silently ignore kare.
    _userPaused = true;
    _disarmStallWatchdog();
    _cancelSkipDebounce();
    await player.stop();
    // BUG FIX (2026-09-18): dekho play() ka poora comment — `stop()` pehle
    // `phase` ko bilkul touch nahi karta tha, isliye agar ye kisi beech-ke
    // resolve (buffering/resolving/retrying) ke dauraan aata, phase wahi
    // FROZEN reh jaata, permanently, chahe baad me kuch bhi ho. `stop()`
    // ek definitive/terminal action hai, isliye ab explicit `idle` pe reset
    // karte hain — `_playToken` abhi-abhi bump hua hai, isliye ye `_setPhase`
    // call guard se guzar jaata hai (token match) aur status message bhi
    // saath hi clear ho jaata hai.
    _setPhase(_playToken, PlaybackPhase.idle);
    await super.stop();
    _logCtl('stop() DONE');
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
  // FIX (v94): jab debounce Timer cancel hota tha (naya playWithRetry ya stop()),
  // purane call ka Completer kabhi complete nahi hota tha -> `await playWithRetry()`
  // hamesha ke liye latka rehta tha (Radio me isse `_transitioning` stuck ho sakta hai).
  Completer<void>? _skipDebounceCompleter;

  void _cancelSkipDebounce() {
    _skipDebounce?.cancel();
    _skipDebounce = null;
    final c = _skipDebounceCompleter;
    _skipDebounceCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  // v55 Radio Enhanced: Radio owns its own candidate/history/error transitions.
  // When this flag is true, the global just_audio completion listener must not
  // also advance QueueService.
  //
  // Radio additionally tracks the active Song independently of QueueService so
  // stream-drop recovery always targets the visible/playing Radio candidate.
  //
  // Radio Player owns its own candidate/history transitions. When this flag
  // is true, the global just_audio completion listener must not also advance
  // QueueService, otherwise one completed Radio song can trigger two next
  // transitions. This is an additive hook; normal queue playback is unchanged.
  bool _radioPlaybackOwned = false;
  Future<void> Function()? _radioNextHandler;
  Future<void> Function()? _radioPreviousHandler;
  Future<void> Function(Song song)? _radioErrorHandler;
  Song? _activePlaybackSong;

  // RADIO OWNER LOCK (v81): an old Radio screen can dispose while a new
  // Radio screen is already being created. Previously dispose() called
  // setRadioPlaybackOwned(false) unconditionally, so the old screen could
  // switch Radio OFF and stop the NEW screen's player. The real-device log
  // showed exactly that sequence: a new candidate reached playing=true, then
  // an old dispose() stopped it and the new transition was reported as
  // failed. Owner ids make release conditional.
  int _radioOwnerSequence = 0;
  int? _radioOwnerId;

  int claimRadioPlaybackOwned({
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
    Future<void> Function(Song song)? onError,
  }) {
    final ownerId = ++_radioOwnerSequence;
    AppLogger.instance.log(
      '[RADIO] claimRadioPlaybackOwned() — owner #$ownerId ON (Radio screen playback control karega)',
    );
    _radioOwnerId = ownerId;
    _radioPlaybackOwned = true;
    _radioNextHandler = onNext;
    _radioPreviousHandler = onPrevious;
    _radioErrorHandler = onError;

    // Invalidate stale resolve/recovery work from the previous Radio owner.
    _playToken++;
    _playbackStartedToken = null;
    _streamErrorRetries = 0;
    return ownerId;
  }

  Future<void> releaseRadioPlaybackOwned(int ownerId) async {
    if (_radioOwnerId != ownerId) {
      AppLogger.instance.log(
        '[RADIO] releaseRadioPlaybackOwned(owner #$ownerId) IGNORED — current owner #${_radioOwnerId ?? "none"}',
      );
      return;
    }

    AppLogger.instance.log(
      '[RADIO] releaseRadioPlaybackOwned(owner #$ownerId) — Radio mode OFF',
    );
    _radioOwnerId = null;
    _radioPlaybackOwned = false;
    _radioNextHandler = null;
    _radioPreviousHandler = null;
    _radioErrorHandler = null;

    // Invalidate in-flight work. Delay the actual stop by one event-loop turn
    // so a new Radio screen can claim ownership first; in that case this old
    // release must NOT stop the new owner's source.
    _playToken++;
    _playbackStartedToken = null;
    _streamErrorRetries = 0;
    final sequenceAtRelease = _radioOwnerSequence;
    await Future<void>.delayed(Duration.zero);
    if (_radioOwnerSequence != sequenceAtRelease || _radioOwnerId != null) {
      AppLogger.instance.log(
        '[RADIO] stale release stop cancelled — new owner appeared.',
      );
      return;
    }
    try {
      await stop();
    } catch (_) {}
  }

  // Compatibility for any older caller. RadioPlayerScreen uses the
  // owner-aware claim/release API above.
  void setRadioPlaybackOwned(
    bool owned, {
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
    Future<void> Function(Song song)? onError,
  }) {
    if (owned) {
      claimRadioPlaybackOwned(
        onNext: onNext,
        onPrevious: onPrevious,
        onError: onError,
      );
    } else {
      final owner = _radioOwnerId;
      if (owner != null) unawaited(releaseRadioPlaybackOwned(owner));
    }
  }

  /// Radio-only warm-up. This resolves the next few stream URLs without
  /// downloading full tracks or touching the active player source. The queue
  /// stays serialized to avoid extraction bursts; each item gets one retry.
  Future<void> prefetchRadioSongs(Iterable<Song> songs) async {
    final list = songs
        .where((song) => song.id != _activePlaybackSong?.id)
        .take(_prefetchWindow)
        .toList(growable: false);
    final keepIds = list.map((song) => song.id).toSet();
    _retainPrefetchQueue(keepIds);
    AppLogger.instance.log(
      '[RADIO] prefetchRadioSongs() called — ${list.length} candidates: '
      '${list.map((s) => s.title).join(", ")}',
    );
    for (final song in list) {
      _enqueuePrefetch(song);
    }
  }

  void _notifyPlaybackError(Song song) {
    if (_radioPlaybackOwned && _radioErrorHandler != null) {
      unawaited(_radioErrorHandler!(song));
      return;
    }
    onError?.call('"${song.title}" play nahi ho paya. Koi aur gaana try karein.');
  }

  @override
  Future<void> skipToNext() async {
    _logCtl('skipToNext() called');
    if (_radioPlaybackOwned && _radioNextHandler != null) {
      AppLogger.instance.log('[RADIO] skipToNext() — Radio-owned, delegating to Radio next handler.');
      await _radioNextHandler!();
      return;
    }
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
    // v106: "aakhri" ab PLAY ORDER ke hisaab se (shuffle ON mein physical
    // `queue.length - 1` galat hota) — `isLastInPlayOrder` dono modes cover
    // karta hai.
    final wasLastWithNoRepeat =
        q.repeat == SurRepeatMode.off && q.isLastInPlayOrder;
    q.next();
    if (wasLastWithNoRepeat) {
      AppLogger.instance.log('[CTL] skipToNext() — queue ka aakhri gaana tha, repeat OFF — stop() kiya, replay nahi.');
      await stop();
      return;
    }
    await _playCurrentFromQueue();
  }

  @override
  Future<void> skipToPrevious() async {
    _logCtl('skipToPrevious() called');
    if (_radioPlaybackOwned && _radioPreviousHandler != null) {
      AppLogger.instance.log('[RADIO] skipToPrevious() — Radio-owned, delegating to Radio previous handler.');
      await _radioPreviousHandler!();
      return;
    }
    QueueService.instance.previous();
    await _playCurrentFromQueue();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _logCtl('setShuffleMode() called', '$shuffleMode');
    final on = shuffleMode != AudioServiceShuffleMode.none;
    QueueService.instance.setShuffle(on);
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _logCtl('setRepeatMode() called', '$repeatMode');
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
  Future<void> playSong(Song song, String url, {String? format}) {
    _activePlaybackSong = song;
    // BUG FIX (2026-09-18, v59): dekho playWithRetry() ka same comment.
    _userPaused = false;
    // BUG FIX (2026-09-18, real-device log): ChunkedYoutubeAudioSource
    // (dekho chunked_audio_source.dart ka poora comment-history — 4
    // attempts already) abhi bhi ~100% fail ho raha hai turant "Source
    // error" ke saath, phir plain setUrl() retry pe chal jaata hai — har
    // gaane pe isi wajah se 1-4 sec ka visible retry-storm (buffering-
    // stuck jaisa lagta hai, notification bhi isi wajah se baar-baar
    // idle/loading flicker karti hai), aur Radio mode isi wajah se poori
    // tarah fail ho gaya (12/12 candidates, dekho [RADIO] log). Chunking
    // ka speed-fayda is reliability cost ke saamne worth nahi — DISABLE
    // kar diya, wapas seedha plain setUrl() (jo log me consistently
    // pehli hi try me chalta hai jab bhi try hota hai).
    return _playSong(song, url, ++_playToken,
        useHeaders: false, useChunking: false, format: format);
  }

  // BUG FIX (2026-09-17, Attempt #5 RESULT — real-device log confirm
  // kiya): "WITH cdnHeaders" (desktop Chrome UA) har baar turant "Source
  // error" deta tha; "WITHOUT headers" (raw URL, jaisa real native
  // client bhejta) attempts ke baad koi aur drop log nahi hua — matlab
  // WAHI sahi strategy hai. Ab "WITHOUT headers" hi PRIMARY/default hai;
  // "WITH headers" sirf ek dur ka fallback rahega (retry ke ek attempt
  // me) — kabhi kisi rare stream ko fir bhi unki zaroorat pad jaaye.
  bool _useHeadersForAttempt(int attemptNumber) => attemptNumber == 2;

  Future<void> _playSong(
    Song song,
    String url,
    int token, {
    required bool useHeaders,
    // SPEED FIX (2026-09-18, re-attempt — dekho chunked_audio_source.dart
    // ka top comment: pichhli baar wala bug (assumed-vs-actual
    // content-length mismatch) is baar fix kiya gaya hai). Risk kam
    // rakhne ke liye: fresh-play call-sites (playSong/playWithRetry) hi
    // `true` bhejte hain — koi bhi stream-drop RETRY (_retryAfterStreamDrop)
    // isko default `false` hi rakhta hai, turant wapas proven-reliable
    // plain `setUrl()` pe. Matlab worst case bhi utna hi reliable jitna
    // pehle (v61) tha (bas ek extra retry lagega), best case gaana fast
    // load hoga bina kisi retry ke.
    bool useChunking = false,
    // BUG FIX (2026-09-18): dekho chunked_audio_source.dart "ATTEMPT #4" —
    // resolve-time-known asli format ("webm"/"mp4"/"m4a"), chunked path ko
    // sahi MIME-type force karne ke liye chahiye. `useChunking: false` ke
    // liye irrelevant (setUrl khud sniff karta hai).
    String? format,
    // BUG FIX (network drop resume): dekho upar `_streamDropResumePosition`
    // ka comment. Null hone par (normal fresh play — user ne khud gaana
    // choose kiya, ya recovery kisi PURANE/alag gaane ke liye thi) purana
    // hamesha-0-se-shuru behavior bilkul waisa hi rehta hai.
    Duration? resumeAt,
  }) async {
    if (token != _playToken) return; // ek naya request already aa chuka hai
    mediaItem.add(_toMediaItem(song));
    _setPhase(token, PlaybackPhase.buffering, 'Buffering...');
    try {
      print(
        'YT PLAY ATTEMPT: "${song.title}" — headers: ${useHeaders ? "WITH cdnHeaders (desktop UA)" : "WITHOUT headers (raw URL, native-client jaisa)"}'
        '${useChunking ? " — CHUNKED (speed-fix)" : ""}',
      );
      // BUG FIX (2026-09-18 — "buffer hamesha ke liye stuck, Radio ek baar
      // fail hone ke baad permanent band"): asli root cause yahi thi —
      // `player.setUrl()`/`setAudioSource()` ke upar KOI timeout nahi tha.
      // `getAudioUrlAndFormat()` (URL resolve) ka apna 60s timeout hai, aur
      // stream-drop retry (`_handleStreamDrop`/`_retryAfterStreamDrop`) ka
      // poora "fresh URL nikaal ke retry karo" mechanism already maujood
      // hai — lekin dono sirf tab trigger hote hain jab koi Future actually
      // throw kare. Jab URL mil chuka ho (naya ya `_urlCache` se cached)
      // lekin just_audio ka setUrl khud CDN pe silently stall ho jaaye (na
      // error, na completion), ye `await` hamesha ke liye latka reh jaata
      // tha — kabhi na throw karta, na complete. Isi wajah se: (1) neeche
      // ka `catch` kabhi nahi chalta, `_handleStreamDrop()` kabhi call hi
      // nahi hota, koi naya URL kabhi try nahi hota (chicken-egg — purana
      // chain kabhi free nahi hota); (2) `_playCandidate`/`playWithRetry`
      // ko await karne wale saare callers (Radio ka `_advance()`/
      // `_previous()`) bhi hamesha ke liye latak jaate, isliye unka
      // `_transitioning` flag kabhi `false` nahi hota — Next/Previous
      // button disabled + spinner permanently stuck, aur swipe gesture
      // (jo `_transitioning` check nahi karta) sirf queue hoke reh jaata,
      // kabhi drain nahi hota. Fix: is stall ko bhi ek explicit timeout se
      // "fail" bana do — taaki wahi already-existing catch → stream-drop
      // → fresh-URL-retry chain fire ho, aur uske through `_transitioning`/
      // `finally` blocks bhi normally unwind ho jaayein.
      const setUrlTimeout = Duration(seconds: 20);
      // Every source replacement first invalidates/cancels the previous
      // native prepare as far as just_audio allows, then gets a fresh
      // generation for this exact attempt.
      final myGen = ++_setUrlGeneration;
      _lastSourceSwitchAt = DateTime.now();
      await _abortInFlightSetUrl();
      if (myGen != _setUrlGeneration || token != _playToken) return;

      Future<Duration?> prepare;
      if (useChunking) {
        // SPEED FIX: chunked HTTP Range source — dekho
        // chunked_audio_source.dart ka top comment (poora root-cause +
        // fix explanation).
        prepare = player.setAudioSource(
          ChunkedYoutubeAudioSource(
            url,
            headers: useHeaders ? YoutubeService.cdnHeaders : null,
            expectedFormat: format,
          ),
        );
      } else {
        prepare = player.setUrl(
          url,
          headers: useHeaders ? YoutubeService.cdnHeaders : null,
        );
      }
      _activeSetUrlOperation = prepare;
      try {
        await prepare.timeout(setUrlTimeout);
      } finally {
        if (identical(_activeSetUrlOperation, prepare)) {
          _activeSetUrlOperation = null;
        }
      }
      // BUG FIX (v101): agar is await ke DAURAAN (chahe timeout ho gaya ho
      // aur ye ab tak-return-na-hui exception ke baad bhi chalta raha ho)
      // ek naya retry/attempt already shuru ho chuka hai (generation aage
      // badh chuka), to ye result STALE hai — ise poori tarah discard karo.
      // Seek/play/mediaItem/token kuch bhi is stale attempt ke naam par
      // touch nahi hona chahiye, warna ye purana attempt naye (asli-current)
      // attempt ke upar apni state thop sakta hai.
      if (myGen != _setUrlGeneration) {
        print('YT PLAY: stale setUrl attempt (gen $myGen, current '
            '$_setUrlGeneration) completed late — discard kiya.');
        return;
      }
      if (token != _playToken) return; // setUrl ke dauraan koi naya tap aa gaya
      // BUG FIX (2026-09-18 — user report: "next/previous kaam nahi karta
      // jab tak gaana khud khatam na ho"): real-device log se confirm hua —
      // kabhi-kabhi ek naya setUrl() apne aap hi non-zero position (kabhi
      // to gaane ke bilkul END ke bराबर) se resolve ho jaata tha, jisse
      // player turant `completed` state pe pahunch jaata (buffering→ready→
      // completed sab 1 second ke andar) — Radio turant agla gaana pe
      // auto-advance kar deta, aur is se Next/Previous "kaam hi nahi kiya"
      // jaisa lagta tha (asal mein play ho ke turant khatam ho jaata tha).
      // Fix: har naye source ke baad explicit seek(0) — guarantee karta hai
      // ki har gaana HAMESHA shuru se bajta hai, chahe internal player
      // state kuch bhi carry kar raha ho. EXCEPT: jab ye ek network-drop
      // RECOVERY hai isi gaane ke liye (`resumeAt` set), tab 0 pe nahi,
      // us purani position pe seek karte hain jahan se gaana cut hua tha.
      try {
        await player.seek(resumeAt ?? Duration.zero);
      } catch (_) {}
      // Consume karke turant clear — agli koi bhi call (chahe isi gaane
      // ka agla retry ho ya bilkul naya gaana) is purani position ko
      // dobara galti se reuse na kare.
      if (resumeAt != null && _streamDropSongId == song.id) {
        _streamDropResumePosition = null;
        _streamDropSongId = null;
      }
      if (token != _playToken) return;
      // IMPORTANT: just_audio's `play()` Future is NOT a "started" signal.
      // Its Future completes when playback later finishes/pauses/stops.
      // Awaiting it here keeps our phase stuck at Buffering for the whole
      // song, even though audio is already playing. That was the exact
      // reason the UI could show a spinner at 0:18 while the song was
      // perfectly smooth. Fire the command without awaiting completion,
      // then wait only for the actual player-start signal below.
      unawaited(player.play().catchError((Object e, StackTrace st) {
        AppLogger.instance.logError('player.play() failed', e, st);
      }));

      // just_audio publishes playing=true as soon as the player has accepted
      // the play command (and keeps it true during normal buffering). We wait
      // for that signal, with a small position-advance fallback for devices
      // where the state publication is delayed.
      if (!await _waitUntilPlaying()) {
        throw StateError(
          'player.play() ke baad playback-start confirm nahi hua '
          '(playing=true ya position advance dono nahi mila)',
        );
      }
      if (token != _playToken) return;
      _armStallWatchdog(token);
      _setPhase(token, PlaybackPhase.playing);
      // Part 3 (Library smarts): asli play-history record — "Recently
      // Played"/"Most Played" ke liye. Fire-and-forget, playback ko kabhi
      // block/fail nahi karega.
      unawaited(PlayHistoryDB.instance.recordPlay(song));
      // Playback successfully shuru ho gaya — stream-drop retry counter
      // reset karo taaki agli baar drop hone pe wapas poore 3 attempts milein.
      _streamErrorRetries = 0;
      // BUG FIX (v98): is gaane ka "given up" flag bhi saaf karo — agar
      // future mein isi gaane pe dobara genuinely fresh drop ho (abhi
      // successfully bajna shuru ho chuka hai), naya retry-cycle milna
      // chahiye, purani "given up" state nahi.
      if (_givenUpSongId == song.id) _givenUpSongId = null;
      // Cache background me ho jaaye — playback ruke bina. Radio me is full
      // track download ko thoda defer karte hain, kyunki next-song URL warm-up
      // ko weak network par pehle bandwidth milni chahiye. Ye playback ko block
      // nahi karta aur non-Radio songs ka existing immediate-cache behavior
      // same rehta hai.
      final radioOwnedAtStart = _radioPlaybackOwned;
      Future<void> cacheAfterPriorityWarmup() async {
        if (radioOwnedAtStart) {
          await Future.delayed(const Duration(seconds: 6));
          if (!_radioPlaybackOwned ||
              token != _playToken ||
              _activePlaybackSong?.id != song.id) {
            return;
          }
        }
        final cacheFuture = _autoCacheInBackground(song, url, markAsPlayed: true);
        try {
          await cacheFuture;
        } finally {
          // BUG FIX (2026-09-17 — user report: "auto-download cache se nahi
          // aata, seedha download mein laga deta hai"): pehle auto-download
          // cache completion ka wait kiye bina queue hota tha, isliye cache
          // row ready hone se pehle duplicate network download start ho sakta
          // tha. Ab download decision cache attempt ke baad hi hota hai.
          await _maybeAutoDownload(song);
        }
      }
      unawaited(cacheAfterPriorityWarmup());
      // Agla gaana bhi abhi se resolve karna shuru kar do (instant next ke liye)
      _prefetchNext();
    } catch (e) {
      if (token != _playToken) return;
      // BUG FIX (2026-09-17): ye catch block hi asli gap tha — agar URL
      // resolve to ho jaata (getAudioUrl OK) lekin just_audio ka
      // player.setUrl()/player.play() khud fail karta (expired URL, CDN
      // 403 jab actually stream karte waqt, codec/format issue, etc.),
      // to sirf ek SnackBar dikhta tha jo gayab ho jaata — file log me
      // KUCH bhi nahi likha jaata tha. Isliye "sab gaane fail ho rahe
      // hain" waale sessions me bhi log khaali dikhta tha. Ab explicit
      // likhte hain.
      print('YT PLAYER FAIL: "${song.title}" (${song.id}) — URL mila tha '
          'lekin just_audio play nahi kar paya: $e');
      // URL kharab nikla — processing state error kar do, UI ko pata chal jaaye
      _setPhase(token, PlaybackPhase.error, 'Playback fail: $e');
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          playing: false,
        ),
      );
      // BUG FIX (2026-09-18, real-device log): pehle yahan seedha
      // `_notifyPlaybackError(song)` call hota tha — lekin yahi failure
      // (CDN drop) lagbhag hamesha `player.playbackEventStream`'s async
      // `onError` pe BHI fire hoti hai (dekho upar wala listener), jo
      // `_handleStreamDrop()` ko call karta hai — matlab EK hi failure ke
      // liye DO independent paths radio/UI ko error batate the, bina kisi
      // retry-budget coordination ke. Log me isi wajah se ek hi gaane ke
      // liye radio ka error-handler lagatar 7 baar back-to-back fire hua
      // tha (koi gap nahi, koi retry nahi — seedha 7 duplicate calls).
      // Fix: yahan bhi `_handleStreamDrop()` hi call karo — wahi ek single
      // retry-budgeted (max 3) state-machine hai; agar async stream ne
      // already ek attempt count kar li hai to ye usi counter ko continue
      // karega (duplicate nahi), aur agar ye ek purely-synchronous error
      // hai (async stream kabhi fire hi nahi hui) to bhi properly retry +
      // ek hi final notify milega.
      _handleStreamDrop();
    }
  }

  // NEW (v41): "Auto-download on Play" setting — dekho settings_screen.dart
  // ('setting_auto_download_on_play', default OFF).
  Future<void> _maybeAutoDownload(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('setting_auto_download_on_play') ?? false;
      if (!enabled) return;
      if (await DownloadDB.instance.exists(song.id)) return;
      if (DownloadQueueService.instance.isActive(song.id)) return;
      DownloadQueueService.instance.enqueue(song);
    } catch (_) {
      // Auto-download fail ho to bhi playback pe asar nahi padna chahiye.
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
    _setUrlGeneration++;
    _playbackStartedToken = null;
    _activePlaybackSong = song;
    _lastSourceSwitchAt = DateTime.now();
    await _abortInFlightSetUrl();
    if (token != _playToken) return;
    // BUG FIX (2026-09-18): dekho `_resolving` ka comment — ye yahan turant
    // (purana gaana pause karne se bhi PEHLE) set karte hain, taaki
    // 300ms-debounce window ke dauraan bhi (jab purana gaana already
    // pause ho chuka hai lekin `_setPhase(resolving)` abhi aaya nahi) Play
    // dabana galti se purana gaana resume na kar de.
    _resolving = true;
    // BUG FIX (2026-09-18, v59): naya song select karna kabhi bhi "user
    // paused" state nahi hota — varna agar theek pehle wale gaane ko pause
    // kiya gaya tha, naya gaana bhi silently us stale flag ki wajah se
    // stream-drop recovery ke bina reh jaata.
    _userPaused = false;
    // Naya song select hua — purane song ke stream-drop retries ka count
    // carry-forward nahi hona chahiye.
    _streamErrorRetries = 0;
    // BUG FIX (v98): dekho `_givenUpSongId` ka comment — ye ek FRESH play
    // decision hai (UI tap ya Radio recovery), isliye ise hamesha apna
    // poora retry-budget milna chahiye, chahe ye SAME song ho jise pehle
    // "given up" mark kiya gaya tha.
    _givenUpSongId = null;

    // BUG FIX (2026-09-16, v12): "gaana change karo to photo/naam turant
    // badal jaata hai lekin AUDIO purana hi 10-12 sec tak bajta rehta hai,
    // aur notification ka time bhi purane gaane ka hi chalta rehta hai".
    // Root cause: mediaItem turant naye gaane ka set ho jaata tha, lekin
    // PURANE `player` ko kabhi pause/stop nahi kaha jaata tha — wo apna
    // resolve (NewPipe/retry pipeline, jo 10-12 sec tak le sakta hai) khatam
    // hone tak bajta hi rehta tha, poori tarah unaware ki UI pe ek naya
    // (different) gaana already dikh raha hai. Fix: naya gaana tap hote hi
    // sabse pehle purane audio ko pause karo, taaki "wrong song" kabhi na
    // baje — silence better hai galat gaane se.
    if (token == _playToken) {
      try {
        if (_radioPlaybackOwned) {
          // Radio switches are atomic: stop clears the previous source/duration
          // before the new MediaItem is published, so the timeline cannot show
          // a stale total from the previous song. Normal playback keeps the
          // existing pause-only behavior to avoid changing the wider app.
          await player.stop();
        } else {
          await player.pause();
        }
      } catch (_) {
        // Empty player state can throw on either path — best effort only.
      }
    }
    if (token != _playToken) return; // pause ke dauraan koi naya tap aa gaya

    mediaItem.add(_toMediaItem(song));
    playbackState.add(
      playbackState.value.copyWith(
        // BUG FIX (crash log 2026-09-16, v11): pehle yahan `controls` ko
        // sirf 1 item (`stop`) tak shrink kiya jaata tha, jabki
        // `androidCompactActionIndices` purani [0,1,3] wali value carry
        // forward karta tha — is mismatch se Android crash karta tha
        // (`setShowActionsInCompactView: action 1 out of bounds`).
        //
        // BUG FIX (2026-09-16, v12): us v11 fix ka side-effect tha —
        // `androidCompactActionIndices: [0]` ke saath notification
        // 10-12 sec tak sirf EK hi button (Stop) wali "skeleton" state me
        // atka reh jaata tha, aur MIUI jaisi OEMs is 1-button state ko
        // khaali/bina-buttons dikha deti hain (screenshot me yahi dikha).
        // Isse bhi bura: agar ismein koi naya `playbackEventStream` event
        // nahi aata (steady state me aisa hona normal hai), to notification
        // waisi hi atki reh jaati thi jab tak naya URL resolve na ho jaaye.
        // Fix: loading ke dauraan bhi HAMESHA standard 4-control set
        // (previous/play-pause/stop/next) hi use karo — jaise normal
        // playback me hota hai — sirf `playing: false` aur
        // `processingState: loading` badlo. Isse controls/indices ka size
        // kabhi mismatch nahi hota (crash-safe) aur notification hamesha
        // full button row dikhata hai, kabhi bhi ek-button "broken" state
        // nahi dikhti.
        controls: const [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 3],
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
    _cancelSkipDebounce(); // purana pending call (agar ho) ka Completer bhi complete karta hai
    final completer = Completer<void>();
    _skipDebounceCompleter = completer;
    _skipDebounce = Timer(
      _radioPlaybackOwned ? Duration.zero : const Duration(milliseconds: 300),
      () async {
        try {
          if (token != _playToken) return;
          // Agar ye Radio ki OUTER recovery hai (`_ensureRecovery`, jo
          // `_handleStreamDrop()` ke apne 3 internal attempts fail hone ke
          // baad chalti hai) usi gaane ke liye jiska drop hua tha, tab bhi
          // wahi captured position use karo — na ki 0.
          final resumeAt =
              _streamDropSongId == song.id ? _streamDropResumePosition : null;
          await _resolveAndPlay(song, token, resumeAt: resumeAt);
        } catch (e) {
          // FIX (v94): _resolveAndPlay se koi bhi unexpected exception aaye
          // to Completer phir bhi complete ho (finally), caller latke nahi.
          print('playWithRetry: _resolveAndPlay unexpected error: $e');
        } finally {
          if (!completer.isCompleted) completer.complete();
          if (identical(_skipDebounceCompleter, completer)) {
            _skipDebounceCompleter = null;
          }
        }
      },
    );
    return completer.future;
  }

  Future<void> _resolveAndPlay(Song song, int token, {Duration? resumeAt}) async {
    _setPhase(token, PlaybackPhase.resolving, 'Stream dhoonda ja raha hai...');

    // BUG FIX (v37 — "next/previous cache se nahi, seedha net se dubara
    // play karta hai"): pehle yahan SABSE PEHLE `_urlCache` (in-memory,
    // sirf ek NETWORK stream URL) check hota tha, aur disk (download/
    // cache) check uske BAAD aata tha. Lekin `_prefetchOne()` (neeche)
    // upcoming gaano ke liye hamesha `_urlCache` bharta hai (jab tak wo
    // song pehle se disk pe na ho) — matlab jab bhi "next/previous" ka sabse
    // common case hota (current gaana bajte hi agla prefetch ho chuka hota
    // hai), `_urlCache` me hamesha ek entry mil jaati thi, aur disk-cache
    // check ko kabhi mauka hi nahi milta tha — isliye har "next" seedha
    // dobara internet se stream karta tha, chahe wahi gaana isi prefetch
    // ke dauraan disk pe bhi save ho chuka ho (`_autoCacheInBackground`
    // dono ek saath karta hai). Fix: DISK (download ya cache) ko hamesha
    // pehle check karo — wahi asli "offline bhi chale, dobara network na
    // lage" wala intent hai. `_urlCache` (network URL) ab sirf ek fallback
    // hai jab disk pe abhi tak kuch nahi bana.
    // (2026-09-18: consolidated — dekho local_media_resolver.dart, ye
    // exact same priority-order jo upar ke comment me describe hui hai)
    final localPath = await LocalMediaResolver.instance.getPath(song.id);
    if (localPath != null) {
      if (token != _playToken) return;
      try {
        // BUG FIX (2026-09-19): dekho `_lastSourceSwitchAt` ka comment
        // (`_playSong()` ke paas) — yahan bhi (local-cache path) source
        // replace ho raha hai, isi guard ki zaroorat hai.
        _lastSourceSwitchAt = DateTime.now();
        await player.setFilePath(localPath);
        if (token != _playToken) return;
        // Dekho _playSong() ka isi tarah ka fix — same guarantee yahan bhi:
        // local cache/download file se bhi HAMESHA position 0 se shuru ho —
        // SIRF jab ye ek network-drop recovery na ho (`resumeAt` null).
        try {
          await player.seek(resumeAt ?? Duration.zero);
        } catch (_) {}
        if (resumeAt != null && _streamDropSongId == song.id) {
          _streamDropResumePosition = null;
          _streamDropSongId = null;
        }
        if (token != _playToken) return;
        // Do not await play(): its Future completes when playback ends/pauses.
        // We only need the immediate command plus a start-state confirmation.
        unawaited(player.play().catchError((Object e, StackTrace st) {
        AppLogger.instance.logError('player.play() failed', e, st);
      }));
        if (!await _waitUntilPlaying()) {
          throw StateError('local file play() ke baad playing=true nahi hua');
        }
        if (token != _playToken) return;
        _setPhase(token, PlaybackPhase.playing);
        // Part 3 (Library smarts): local-first (cache/download) play bhi
        // history me record hona chahiye, warna offline-heavy users ke
        // liye "Most/Never Played" hamesha khali/galat rahega.
        unawaited(PlayHistoryDB.instance.recordPlay(song));
        // BUG FIX (isi session — auto-download sirf network-play path pe
        // trigger hota tha, is local-file-first path pe bilkul nahi thi).
        // Ab agar ye gaana sirf CACHE me tha (Download me nahi) aur
        // auto-download ON hai, wahan bhi trigger hoga — `_maybeAutoDownload`
        // khud DownloadDB check karta hai, isliye already-downloaded case
        // me ye turant harmless no-op hoga.
        unawaited(_maybeAutoDownload(song));
        // LRU freshen karo taaki abhi-abhi replay hua gaana jaldi evict
        // na ho (pichla/replay hua gaana cache me tika rahe).
        await CacheDB.instance.update(
          song.id,
          lastPlayed: DateTime.now().millisecondsSinceEpoch,
        );
        // Ab disk se bajaya — ye stale network URL kabhi kaam nahi
        // aayega (agar galti se abhi bhi pada tha), hata do.
        _urlCache.remove(song.id);
        _prefetchNext();
        return;
      } catch (e) {
        // Local file corrupt/missing nikla — normal network resolve pe
        // fallback karo (neeche wala loop/urlCache).
      }
    }

    // Disk pe kuch nahi mila — agar ye song already prefetch ho ke
    // network-URL cache me pada hai (skipToNext ka doosra common case,
    // jab prefetch abhi resolve hi hua ho, disk-write abhi baaki ho),
    // seedha usi URL se play karo — koi naya NewPipe/explode/Piped
    // resolve nahi, isliye "next" ab bhi instant hai.
    final cached = _freshWarmUrl(song.id);
    if (cached != null) {
      _urlCache.remove(song.id);
      await _playSong(
        song,
        cached.url,
        token,
        useHeaders: false,
        // BUG FIX (2026-09-18): dekho playSong() ka comment — chunking
        // disabled, real-device pe ~100% fail hoti thi.
        useChunking: false,
        format: cached.format,
        resumeAt: resumeAt,
      );
      return;
    }

    for (var attempt = 1; attempt <= 3; attempt++) {
      // BUG FIX (2026-09-16, v5): agar is dauraan user ne koi aur gaana
      // tap kar diya (_playToken aage badh gaya), to ye purana attempt
      // chup-chaap ruk jaata hai — na error dikhata, na retry karta, na
      // kisi cheez ko overwrite karta.
      if (token != _playToken) return;
      if (attempt > 1) {
        _setPhase(token, PlaybackPhase.retrying, 'Try $attempt/3...');
      }

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
      String? format;
      try {
        final resolved = await YoutubeService.instance
            .getAudioUrlAndFormat(song.id, title: song.title, author: song.artist)
            .timeout(const Duration(seconds: 60));
        url = resolved?.url;
        format = resolved?.format;
      } on TimeoutException {
        print('playWithRetry: attempt $attempt timed out after 60s');
        url = null;
      }
      if (token != _playToken) return; // resolve hone tak user aage badh chuka
      if (url != null) {
        await _playSong(
          song,
          url,
          token,
          useHeaders: false,
          // BUG FIX (2026-09-18): dekho playSong() ka comment — chunking
          // disabled, real-device pe ~100% fail hoti thi (isi wajah se
          // saara buffering-stuck/notification-flicker/Radio-crash issue).
          useChunking: false,
          format: format,
          resumeAt: resumeAt,
        );
        return;
      }
      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    // Teeno attempts fail — error state (sirf agar ye ab bhi latest request hai)
    if (token != _playToken) return;
    _setPhase(token, PlaybackPhase.error, 'Stream URL nahi mila (3 attempts fail)');
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
      ),
    );
    _notifyPlaybackError(song);
  }

  // Local file se play karo — downloaded ya already-cached songs ke liye
  //
  // BUG FIX (user screenshot, 2026-09-18 — "White Brown Black bajta hai
  // [pause icon = actually playing], lekin upar 'Buffering...' atka hua
  // dikhata hai, saath me ek DUSRE gaane ka purana error bhi neeche dikh
  // raha hai"): ye function pehle kabhi `phase` (custom ValueNotifier jo
  // subtitle text drive karta hai — dekho full_player_screen.dart) ko
  // `PlaybackPhase.playing` set hi nahi karta tha — sirf `player.play()`
  // call hota tha. `player.play()` khud `playbackState`
  // (`_broadcastState()` ke through) ko turant update kar deta hai, isliye
  // PLAY/PAUSE ICON turant sahi dikhta hai — lekin subtitle text (`phase`)
  // jo bhi PICHLI value pe tha (jaise koi pehle wala gaana stream-resolve
  // karte waqt "Buffering..."/"Error" pe atka tha) wahi hamesha ke liye
  // reh jaata tha, kyunki isko RESET karne wala koi call hi missing tha.
  // Isi wajah se "downloaded gaana tap karo (jo playFromFile() use karta
  // hai) turant baja bhi de, phir bhi text purani stuck state dikhata
  // rahe" — exactly jaisa screenshot me dikha. Fix: doosri saari
  // play-methods (`_playSong`, `_resolveAndPlay` ka local-path) ki tarah
  // yahan bhi explicit `_setPhase()` calls add kiye — start pe buffering,
  // success pe playing, fail pe error — taaki `phase` kabhi stale na rahe.
  Future<void> playFromFile(Song song, String filePath) async {
    final token = ++_playToken;
    _playbackStartedToken = null;
    _activePlaybackSong = song;
    // BUG FIX (2026-09-18, v59): dekho playWithRetry() ka same comment.
    _userPaused = false;
    mediaItem.add(_toMediaItem(song.copyWith(filePath: filePath)));
    _setPhase(token, PlaybackPhase.buffering, 'Buffering...');
    try {
      final myGen = ++_setUrlGeneration;
      _lastSourceSwitchAt = DateTime.now();
      await _abortInFlightSetUrl();
      if (myGen != _setUrlGeneration || token != _playToken) return;

      final filePrepare = player.setFilePath(filePath);
      _activeSetUrlOperation = filePrepare;
      try {
        await filePrepare;
      } finally {
        if (identical(_activeSetUrlOperation, filePrepare)) {
          _activeSetUrlOperation = null;
        }
      }
      if (myGen != _setUrlGeneration || token != _playToken) return;
      // Do not await play(): its Future completes when playback ends/pauses.
      unawaited(player.play().catchError((Object e, StackTrace st) {
        AppLogger.instance.logError('File player.play() failed', e, st);
      }));
      if (!await _waitUntilPlaying()) {
        throw StateError('file play() ke baad playing=true nahi hua');
      }
      if (token != _playToken) return;
      _armStallWatchdog(token);
      _setPhase(token, PlaybackPhase.playing);
      // Part 3 (Library smarts): playFromFile bhi ek "real" play hai.
      unawaited(PlayHistoryDB.instance.recordPlay(song));
    } catch (e) {
      if (token != _playToken) return;
      _setPhase(token, PlaybackPhase.error, 'File corrupt/missing');
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

  MediaItem _toMediaItem(Song song, {String? statusOverride}) {
    // BUG FIX (user request, 2026-09-18 — "agle gaane ki photo kitna/kaise
    // load hui, minimum se minimum detail bhi chahiye"): audio_service ka
    // asli artwork-download (`preloadArtwork: true`) native side pe hota
    // hai, Dart se uska progress track nahi ho sakta — isliye yahan sirf
    // itna minimum-detail log kiya hai ki HAR naye mediaItem ke liye
    // artUri kya tha (khaali/missing thumb bhi turant pata chal jaaye,
    // "photo load nahi hui" jaisi shikayat debug karne ke liye).
    if (statusOverride == null) {
      AppLogger.instance.log(
        '[ART] mediaItem: "${song.title}" — thumb: '
        '${song.thumb.isNotEmpty ? song.thumb : "(khaali/missing)"}',
      );
    }
    return MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist, // HAMESHA asli artist — kabhi overwrite nahi hota (dekho _setPhase comment)
      // `album` field Song model/UI mein kahin aur use nahi hoti — isliye
      // isko hi transient phase-status ("Resolving...", "Retry 2/3...")
      // ke liye "borrow" karte hain, bina `artist` ko chhue.
      album: statusOverride,
      artUri: song.thumb.isNotEmpty ? Uri.tryParse(song.thumb) : null,
      // BUG FIX (v98 — user report: notification/quick-settings widget me
      // seekbar kabhi-kabhi bilkul gayab ho jaata hai): pehle yahan
      // `song.duration` 0 hone par bhi `Duration.zero` bhej dete the
      // (kabhi-kabhi YouTube search metadata duration populate hi nahi
      // karta). Kai OEM media-widgets (jaise MIUI ka quick-settings media
      // card) apna seekbar sirf ek baar, mediaItem ke PEHLE snapshot par
      // decide karte hain ki duration "valid" hai ya nahi — 0 ko "no
      // duration" maan ke seekbar hamesha ke liye chhupa dete hain, chahe
      // baad me humara durationStream listener (upar) asli duration se
      // update kar bhi de — stock Android notification jaisa live-refresh
      // nahi karte. Ek downloaded/cached gaane ke liye duration shuru se
      // hi sahi hota hai (isliye ek case theek dikhta tha, doosra nahi);
      // fresh-streamed gaane ke liye search-metadata duration kabhi 0
      // hota hai. Fix: 0/unknown duration par null bhejo ("abhi pata
      // nahi") — jab tak durationStream se asli value na mil jaaye, chahe
      // wo OEM-widget ko re-check karne pe majboor kare.
      duration: song.duration > 0 ? Duration(seconds: song.duration) : null,
      extras: {'filePath': song.filePath},
    );
  }

  // Stream ho raha song ko chupke se cache folder me download karke DB me
  // register karo — agli baar bina internet ke bhi bajega. Playback isse
  // block nahi hota, isliye caller isko await nahi karta.
  // BUG FIX (2026-09-18 — caching-paths audit): ye function 2+ jagah se
  // (`_prefetchOne`/`_prefetchRadioOne` ka background prefetch, AUR
  // `_playSong` khud jab gaana actually chalta hai) SAME song ke liye
  // overlap ho sakta tha — dono `file.exists()` check ko fail dekh ke
  // (abhi tak koi nahi likha) EK SAATH download+write shuru kar dete,
  // aur ek hi disk file pe do parallel writes corrupt/truncated result de
  // sakte the. Fix: per-songId in-flight registry — dusra caller naya
  // download shuru nahi karta, PEHLE wale ka hi Future await kar leta hai.
  final Map<String, Future<void>> _autoCacheInFlight = {};

  Future<void> _autoCacheInBackground(
    Song song,
    String streamUrl, {
    required bool markAsPlayed,
  }) {
    final existing = _autoCacheInFlight[song.id];
    if (existing != null) return existing;
    final future = _autoCacheInBackgroundImpl(song, streamUrl,
            markAsPlayed: markAsPlayed)
        .whenComplete(() => _autoCacheInFlight.remove(song.id));
    _autoCacheInFlight[song.id] = future;
    return future;
  }

  Future<void> _autoCacheInBackgroundImpl(
    Song song,
    String streamUrl, {
    required bool markAsPlayed,
  }) async {
    HttpClient? client;
    File? file;
    try {
      final dir = await CacheService.instance.getAudioCacheDir();
      final filePath = p.join(dir.path, '${song.id}.m4a');
      file = File(filePath);
      if (await file.exists()) {
        if (markAsPlayed) {
          await CacheDB.instance.update(
            song.id,
            lastPlayed: DateTime.now().millisecondsSinceEpoch,
          );
        }
        return;
      }

      client = HttpClient();
      final request = await client.getUrl(Uri.parse(streamUrl));
      final response = await request.close();
      final contentType = response.headers.contentType?.mimeType.toLowerCase();
      final allowedContent = contentType == null ||
          contentType.startsWith('audio/') ||
          contentType.startsWith('video/') ||
          contentType == 'application/octet-stream';

      if (response.statusCode < 200 || response.statusCode >= 300 || !allowedContent) {
        await response.drain<void>();
        throw HttpException(
          'Invalid cache response: ${response.statusCode} ${contentType ?? ''}',
          uri: Uri.tryParse(streamUrl),
        );
      }

      final sink = file.openWrite();
      try {
        await response.pipe(sink);
      } catch (_) {
        await sink.close();
        rethrow;
      }
      await sink.close();

      if (!await file.exists() || await file.length() < 4096) {
        throw const FileSystemException('Cached response is empty/too small');
      }

      await CacheService.instance.cacheSong(
        song,
        filePath,
        markAsPlayed: markAsPlayed,
      );
      // One final DB-level content check catches 200/text-error responses
      // from providers that omit a useful Content-Type header.
      await CacheDB.instance.getRow(song.id);
    } catch (_) {
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    } finally {
      client?.close(force: true);
    }
  }
}
