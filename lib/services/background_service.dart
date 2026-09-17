// lib/services/background_service.dart
// SABSE ZAROORI FILE — actual playback yahi se hota hai. audio_service ke
// BaseAudioHandler ko implement karta hai taaki background play, notification
// controls, aur lock screen controls sab kaam karein.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/cache_db.dart';
import '../db/download_db.dart';
import '../db/play_history_db.dart';
import '../models/song.dart';
import 'cache_service.dart';
import 'equalizer_presets.dart';
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

  // FIX: "next dabane par 10s lagta hai" — pehle next song ka poora
  // resolve (NewPipe/explode/Piped) sirf next tap hone ke BAAD shuru hota
  // tha. Ab current gaana play hote hi agla gaana background me chup-
  // chaap resolve karke yahan cache ho jaata hai — skipToNext() aate hi
  // seedha ye URL use hota hai (instant), koi naya network call nahi.
  final Map<String, String> _urlCache = {};
  final Set<String> _prefetchingIds = {};

  // FIX (user request): sirf agle gaane ka URL cache karna kaafi nahi tha —
  // ab agle 2 upcoming gaane bhi (jab tak current bajta rehta hai) chup-
  // chaap disk pe download/cache ho jaate hain, taaki wo bhi turant aur
  // offline bhi bajein. Pehle se download/cached gaana dobara nahi
  // chhua jaata (koi duplicate network call/write nahi).
  void _prefetchNext() {
    final upcoming = QueueService.instance.upcoming;
    for (final next in upcoming.take(2)) {
      _prefetchOne(next);
    }
  }

  void _prefetchOne(Song next) {
    if (_urlCache.containsKey(next.id) || _prefetchingIds.contains(next.id)) {
      return;
    }
    _prefetchingIds.add(next.id);
    () async {
      try {
        // Pehle se download ya cache me hai to kuch karne ki zaroorat
        // nahi — koi duplicate network/disk call nahi.
        final already = await DownloadDB.instance.getFilePath(next.id) ??
            await CacheDB.instance.getFilePath(next.id);
        if (already != null) return;

        final url = await YoutubeService.instance
            .getAudioUrl(next.id, title: next.title, author: next.artist);
        if (url == null) return;
        _urlCache[next.id] = url; // turant-skip ke liye fallback
        await _autoCacheInBackground(next, url); // disk pe bhi utaar do
      } catch (_) {
        // Prefetch fail hone se playback pe koi asar nahi — normal
        // resolve chain skip/play time pe apne aap fallback ban jaati hai.
      } finally {
        _prefetchingIds.remove(next.id);
        if (_urlCache.length > 5) {
          _urlCache.remove(_urlCache.keys.first);
        }
      }
    }();
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
  static const int _maxStreamErrorRetries = 3;

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
        if (sleepAtEndOfTrack) {
          sleepAtEndOfTrack = false;
          pause();
          onSleepAtEndOfTrackFired?.call();
        } else {
          skipToNext();
        }
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
  void _handleStreamDrop() {
    final token = _playToken;
    final song = QueueService.instance.currentSong;

    if (song != null && _streamErrorRetries < _maxStreamErrorRetries) {
      _streamErrorRetries++;
      print('YT STREAM DROP: "${song.title}" — retry ${_streamErrorRetries}/'
          '$_maxStreamErrorRetries (fresh URL nikaal ke).');
      // Loading state dikhao — user ko "kuch hua hi nahi" na lage jab
      // background me retry chal raha ho.
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.loading,
          playing: false,
        ),
      );
      unawaited(_retryAfterStreamDrop(song, token));
      return;
    }

    // Retries khatam ho gaye (ya current song hi pata nahi) — ab final error
    print('YT STREAM DROP: "${song?.title}" — saare $_maxStreamErrorRetries '
        'retries fail, final error.');
    _streamErrorRetries = 0;
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
  }

  Future<void> _retryAfterStreamDrop(Song song, int token) async {
    // Chhota gap taaki turant-turant CDN ko dobara na maare, network/CDN
    // ko thoda "settle" hone ka time mile.
    await Future.delayed(const Duration(seconds: 1));
    if (token != _playToken) return; // is dauraan user aage badh gaya

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
    );
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
  Future<void> playSong(Song song, String url) =>
      _playSong(song, url, ++_playToken, useHeaders: false);

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
  }) async {
    if (token != _playToken) return; // ek naya request already aa chuka hai
    mediaItem.add(_toMediaItem(song));
    try {
      print(
        'YT PLAY ATTEMPT: "${song.title}" — headers: ${useHeaders ? "WITH cdnHeaders (desktop UA)" : "WITHOUT headers (raw URL, native-client jaisa)"}',
      );
      await player.setUrl(
        url,
        headers: useHeaders ? YoutubeService.cdnHeaders : null,
      );
      if (token != _playToken) return; // setUrl ke dauraan koi naya tap aa gaya
      await player.play();
      // Part 3 (Library smarts): asli play-history record — "Recently
      // Played"/"Most Played" ke liye. Fire-and-forget, playback ko kabhi
      // block/fail nahi karega.
      unawaited(PlayHistoryDB.instance.recordPlay(song));
      // Playback successfully shuru ho gaya — stream-drop retry counter
      // reset karo taaki agli baar drop hone pe wapas poore 3 attempts milein.
      _streamErrorRetries = 0;
      // Cache background me ho jaaye — playback ruke bina
      unawaited(_autoCacheInBackground(song, url));
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
    // Naya song select hua — purane song ke stream-drop retries ka count
    // carry-forward nahi hona chahiye.
    _streamErrorRetries = 0;

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
        await player.pause();
      } catch (_) {
        // player me abhi koi source hi na ho to pause() error de sakta
        // hai — usse ignore karo, ye sirf best-effort silence hai
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
    final localPath = await DownloadDB.instance.getFilePath(song.id) ??
        await CacheDB.instance.getFilePath(song.id);
    if (localPath != null) {
      if (token != _playToken) return;
      try {
        await player.setFilePath(localPath);
        if (token != _playToken) return;
        await player.play();
        // Part 3 (Library smarts): local-first (cache/download) play bhi
        // history me record hona chahiye, warna offline-heavy users ke
        // liye "Most/Never Played" hamesha khali/galat rahega.
        unawaited(PlayHistoryDB.instance.recordPlay(song));
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
    final cached = _urlCache.remove(song.id);
    if (cached != null) {
      await _playSong(song, cached, token, useHeaders: false);
      return;
    }

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
            .timeout(const Duration(seconds: 60));
      } on TimeoutException {
        print('playWithRetry: attempt $attempt timed out after 60s');
        url = null;
      }
      if (token != _playToken) return; // resolve hone tak user aage badh chuka
      if (url != null) {
        await _playSong(song, url, token, useHeaders: false);
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
      // Part 3 (Library smarts): playFromFile bhi ek "real" play hai.
      unawaited(PlayHistoryDB.instance.recordPlay(song));
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
