// lib/services/youtube_service.dart
// YouTube se search, stream URL resolve, aur download karne ka poora kaam.
//
// APPROACH CHANGE (2026-09-16, v2): pichhla version (2026-09-16 ka pehla
// commit) sirf Piped (public proxy instances) use karta tha. Testing me
// pata chala ki Sept 2026 me poore Piped ecosystem ke saare public
// instances effectively down/unreliable hain (502, DNS fail, handshake
// error — dekho standalone test repo "Test-music" ki purani run logs).
// Isliye ab wapas seedha YouTube se (youtube_explode_dart) extract karte
// hain — jo standalone test (`Test-music/bin/piped_test.dart`) me Termux
// (real phone IP) se PASS ho chuka hai. Piped ko poori tarah hataya nahi
// hai — sirf free/zero-cost EXTRA backup layer ban gaya hai (agar kabhi
// koi instance wapas zinda ho jaye, ya youtube_explode_dart kal block ho
// jaye, to ye extra safety net hai). Koi hard dependency Piped pe nahi hai.
//
// *** ARCHITECTURE (dono search aur audio ke liye 2 independent layers) ***
//
// SEARCH:
//   Layer 1: dart_ytmusic_api — YT Music ka apna native search, "music
//            songs" jaisa filter Piped ke `filter: music_songs` se better
//            match karta hai kyunki ye YT Music ka native ranking use
//            karta hai.
//   Layer 2: youtube_explode_dart search — agar YT Music search fail ho
//            ya 0 results de.
//
// AUDIO URL:
//   Layer 1: youtube_explode_dart — seedha YouTube se extract (multiple
//            client surfaces: androidSdkless/ios/androidVr/safari + Deno
//            JS-solver agar device pe available ho). Audio-only streams
//            fail (403/PoToken-restricted) ho to muxed (video+audio)
//            stream fallback try karta hai — muxed alag client-path use
//            karta hai isliye aksar chalta hai jab audio-only nahi
//            chalta; player audio-only track nikaal ke play kar leta
//            hai, thoda extra video data waste hota hai but kaam ho
//            jaata hai.
//   Layer 2: Piped public instances (BACKUP, free extra try) — dono me
//            koi single point of failure share nahi hota.
//
// Isi exact architecture ka standalone Dart CLI version repo
// "jaat888/Test-music" me hai — koi bhi future change pehle wahan test
// karna (GitHub Actions/CI pe NAHI, kyunki GitHub Actions ka IP YouTube ke
// liye datacenter/bot maana jaata hai aur block ho jaata hai — Termux ya
// kisi bhi real phone/PC se test karo).

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:dart_ytmusic_api/yt_music.dart';

import '../db/download_db.dart';
import '../models/song.dart';
import 'storage_service.dart';

// Search/playlist result ka lightweight model — Song se pehle ka staging data
class YtResult {
  final String id;
  final String title;
  final String author;
  final String thumb;
  final int duration; // seconds

  YtResult({
    required this.id,
    required this.title,
    required this.author,
    required this.thumb,
    required this.duration,
  });

  // YtResult ko seedha Song me convert karna ho to
  Song toSong() => Song(
        id: id,
        title: title,
        artist: author,
        thumb: thumb,
        duration: duration,
      );
}

// Ek resolved audio stream — URL + format (extension nikalne ke liye,
// download() ko chahiye) + basic video info (title/author/thumb/duration,
// taaki download ke baad dobara ek extra network call na karni pade).
class _AudioStream {
  final String url;
  final String format; // e.g. "mp4", "webm"
  final String title;
  final String author;
  final String thumb;
  final int duration;

  _AudioStream({
    required this.url,
    required this.format,
    required this.title,
    required this.author,
    required this.thumb,
    required this.duration,
  });
}

class YoutubeService {
  YoutubeService._internal();
  static final YoutubeService instance = YoutubeService._internal();

  // Public Piped instances — ab sirf FREE EXTRA backup hai, primary source
  // NAHI (Sept 2026 me ye ecosystem-wide largely down hai). Order matters,
  // upar wale pehle try hote hain. List
  // https://github.com/TeamPiped/Piped/wiki/Instances se li gayi hai.
  static const List<String> _pipedInstances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.leptons.xyz',
    'https://pipedapi.nosebs.ru',
    'https://pipedapi-libre.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://api.piped.yt',
    'https://pipedapi.drgns.space',
  ];

  // youtube_explode_dart ke manifest fetch me try karne wale client
  // surfaces — androidSdkless PoToken/403-on-audio-only ka known fix hai.
  static final List<YoutubeApiClient> _ytClients = [
    YoutubeApiClient.androidSdkless,
    YoutubeApiClient.ios,
    YoutubeApiClient.androidVr,
    YoutubeApiClient.safari,
  ];

  final http.Client _http = http.Client();

  // youtube_explode_dart client — lazily banta hai, ek baar bante hi
  // reuse hota hai (naya banane me Deno solver dobara init karna padega).
  YoutubeExplode? _yt;
  Future<YoutubeExplode> _getYt() async {
    final existing = _yt;
    if (existing != null) return existing;
    YoutubeExplode created;
    try {
      final solver = await DenoEJSSolver.init();
      created = YoutubeExplode(jsSolver: solver);
    } catch (e) {
      // Deno device pe na ho to bhi chalta hai — thoda kam reliable
      // (kuch videos signature-deciphering maangte hain), but crash nahi
      // hota.
      print('YT: Deno JS solver init nahi hua, bina solver ke aage: $e');
      created = YoutubeExplode();
    }
    _yt = created;
    return created;
  }

  // dart_ytmusic_api client — lazily init hota hai.
  YTMusic? _ytMusic;
  Future<YTMusic> _getYtMusic() async {
    final existing = _ytMusic;
    if (existing != null) return existing;
    final created = YTMusic();
    await created.initialize();
    _ytMusic = created;
    return created;
  }

  // ---------------- Search ----------------

  Future<List<YtResult>> search(
    String query, {
    int max = 30,
    void Function(String status)? onProgress,
  }) async {
    if (query.trim().isEmpty) return [];

    // Layer 1: YT Music native search (music-specific ranking)
    try {
      onProgress?.call('Searching YT Music...');
      final ytmusic = await _getYtMusic();
      final songs = await ytmusic.searchSongs(query);
      final results = <YtResult>[];
      for (final s in songs) {
        if (results.length >= max) break;
        final id = s.videoId;
        if (id.isEmpty) continue;
        results.add(YtResult(
          id: id,
          title: s.name,
          author: s.artist.name,
          thumb: s.thumbnails.isNotEmpty ? s.thumbnails.last.url : '',
          duration: s.duration ?? 0,
        ));
      }
      if (results.isNotEmpty) {
        onProgress?.call('YT Music: OK, ${results.length} results');
        return results;
      }
      print('YT Music search: 0 usable results, YouTube search try kar rahe hain');
      onProgress?.call('YT Music: 0 results, trying YouTube search...');
    } catch (e) {
      print('YT Music search failed: $e');
      onProgress?.call('YT Music failed, trying YouTube search...');
    }

    // Layer 2: youtube_explode_dart direct search (fallback)
    try {
      final yt = await _getYt();
      final videos = await yt.search.getVideos(query);
      final results = videos.take(max).map((v) => YtResult(
            id: v.id.value,
            title: v.title,
            author: v.author,
            thumb: v.thumbnails.highResUrl,
            duration: v.duration?.inSeconds ?? 0,
          )).toList();
      if (results.isNotEmpty) {
        onProgress?.call('YouTube search: OK, ${results.length} results');
      } else {
        print('YT SEARCH ERROR: dono layers (YT Music + explode) se 0 results');
        onProgress?.call('All sources: 0 results.');
      }
      return results;
    } catch (e) {
      print('YT explode search failed: $e');
      onProgress?.call('All sources failed.');
      return [];
    }
  }

  // ---------------- Playlist ----------------

  Future<List<YtResult>> getPlaylist(String playlistId) async {
    try {
      final yt = await _getYt();
      final playlist = await yt.playlists.getVideos(playlistId).toList();
      return playlist
          .map((v) => YtResult(
                id: v.id.value,
                title: v.title,
                author: v.author,
                thumb: v.thumbnails.highResUrl,
                duration: v.duration?.inSeconds ?? 0,
              ))
          .toList();
    } catch (e) {
      print('YT PLAYLIST ERROR: $playlistId ke liye explode se fail: $e');
      return [];
    }
  }

  // ---------------- Audio stream resolve (streaming/download dono ke liye) ----------------

  // Har candidate URL ko ek chhota real HTTP range-request (~1KB) bhejke
  // verify karte hain ki asal me fetch ho pa raha hai ya nahi. "URL mila"
  // aur "URL actually chalta hai" alag check hain (expired/blocked URLs
  // dono sources se aa sakte hain).
  Future<bool> _verifyPlayable(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response =
          await request.close().timeout(const Duration(seconds: 6));
      await response.drain<List<int>>();
      return response.statusCode == 200 || response.statusCode == 206;
    } catch (e) {
      print('Stream verify failed: $e');
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  // ---- Layer 1: seedha YouTube se (youtube_explode_dart) ----
  Future<_AudioStream?> _audioViaExplode(
    String videoId, {
    void Function(String status)? onProgress,
  }) async {
    try {
      onProgress?.call('Resolving via YouTube...');
      final yt = await _getYt();

      // Metadata (title/author/thumb/duration) — best-effort, na mile to
      // bhi audio resolve karna try karte hain.
      String title = 'Unknown';
      String author = 'Unknown Artist';
      String thumb = '';
      int duration = 0;
      try {
        final video =
            await yt.videos.get(videoId).timeout(const Duration(seconds: 10));
        title = video.title;
        author = video.author;
        thumb = video.thumbnails.highResUrl;
        duration = video.duration?.inSeconds ?? 0;
      } catch (e) {
        // BUG FIX: pehle yahan koi timeout nahi tha — agar ye request
        // stall ho jaaye (network hiccup ya YouTube silently connection
        // drop kar de bina kisi error ke), poora flow hamesha ke liye
        // "Resolving via YouTube..." pe atka reh jaata tha (na error, na
        // success) — player 0:00/0:00 pe freeze ho jaata tha. Ab 10s me
        // ye step khud-ba-khud fail ho jaata hai aur aage badh jaate hain.
        print('YT explode: video metadata fetch fail hui ($videoId): $e');
      }

      // BUG FIX: getManifest() pe bhi pehle koi timeout nahi tha — same
      // hang risk. 30s ke baad TimeoutException throw hogi, jo neeche
      // wale catch(e) me pakdi jaake Piped backup layer try karega
      // (poori flow hang nahi hogi).
      final manifest = await yt.videos.streams
          .getManifest(videoId, ytClients: _ytClients)
          .timeout(const Duration(seconds: 30));

      String fmt(Object container) => container.toString().toLowerCase();

      // Audio-only candidates — sabse high bitrate wale pehle try karo.
      final audioStreams = List.of(manifest.audioOnly)
        ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      for (final s in audioStreams) {
        onProgress?.call('Checking audio stream (${s.bitrate})...');
        if (await _verifyPlayable(s.url.toString())) {
          return _AudioStream(
            url: s.url.toString(),
            format: fmt(s.container),
            title: title,
            author: author,
            thumb: thumb,
            duration: duration,
          );
        }
      }

      // Fallback: muxed (video+audio) stream. Audio-only streams kabhi
      // PoToken-restricted (403) hote hain, muxed alag client-path use
      // karta hai isliye aksar chal jaata hai jab audio-only nahi chalta.
      // Sabse chhota size wala pick karte hain (kam extra data waste).
      onProgress?.call('Audio-only failed, trying muxed fallback...');
      final muxedStreams = List.of(manifest.muxed)
        ..sort((a, b) => a.size.totalBytes.compareTo(b.size.totalBytes));
      for (final m in muxedStreams) {
        onProgress?.call('Checking muxed stream (${m.videoQuality})...');
        if (await _verifyPlayable(m.url.toString())) {
          print('YT explode: muxed fallback OK ($videoId), isse audio nikaal ke play karo');
          return _AudioStream(
            url: m.url.toString(),
            format: fmt(m.container),
            title: title,
            author: author,
            thumb: thumb,
            duration: duration,
          );
        }
      }

      print('YT explode: sab audio-only aur muxed candidates fail ho gaye ($videoId)');
      return null;
    } catch (e) {
      print('YT explode failed for $videoId: $e');
      return null;
    }
  }

  // ---- Layer 2: Piped public instances (BACKUP, free extra try) ----
  Future<_AudioStream?> _audioViaPipedBackup(
    String videoId, {
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('YouTube direct failed, trying Piped backup...');
    for (final base in _pipedInstances) {
      onProgress?.call('Trying $base...');
      try {
        final uri = Uri.parse('$base/streams/$videoId');
        final res = await _http.get(uri).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) {
          print('Piped streams: $base returned ${res.statusCode}, trying next');
          onProgress?.call('$base: HTTP ${res.statusCode}, trying next...');
          continue;
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final audioStreams = (data['audioStreams'] as List?) ?? [];
        if (audioStreams.isEmpty) {
          print('Piped streams: $base audioStreams empty, trying next');
          onProgress?.call('$base: no audio stream, trying next...');
          continue;
        }

        final sorted = List<Map<String, dynamic>>.from(audioStreams)
          ..sort((a, b) =>
              ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
        final best = sorted.first;
        final url = best['url'] as String?;
        if (url == null || url.isEmpty) {
          print('Piped streams: $base best stream has no url, trying next');
          continue;
        }

        onProgress?.call('$base: verifying...');
        if (!await _verifyPlayable(url)) {
          print('Piped streams: $base URL bana lekin fetch fail, trying next');
          onProgress?.call('$base: verify failed, trying next...');
          continue;
        }

        onProgress?.call('$base: OK!');
        return _AudioStream(
          url: url,
          format: ((best['format'] as String?) ?? 'm4a').toLowerCase(),
          title: (data['title'] as String?) ?? 'Unknown',
          author: (data['uploader'] as String?) ?? 'Unknown Artist',
          thumb: (data['thumbnailUrl'] as String?) ?? '',
          duration: (data['duration'] as num?)?.toInt() ?? 0,
        );
      } catch (e) {
        print('Piped streams: $base failed: $e');
        onProgress?.call('$base: error, trying next...');
        continue;
      }
    }
    print('YT AUDIO URL ERROR: dono layers (explode + Piped backup) se playable URL nahi mila ($videoId)');
    onProgress?.call('All sources failed.');
    return null;
  }

  // ---- videoId sanity check + self-heal ----
  //
  // BUG FIX (2026-09-16, matched from Test-music/bin/piped_test.dart —
  // jo Termux pe PASS hota tha): app me ye poora step MISSING tha, aur
  // yahi asli wajah thi ki Termux test pass hota tha par app me wahi
  // gaana fail ho jaata tha. dart_ytmusic_api khud "early development,
  // may be unstable" bolta hai — iska videoId field kabhi-kabhi
  // corrupt/wrong nikalta hai (title/author sahi hote hain, par ID
  // asli YouTube par exist hi nahi karta). App pehle ye galat ID seedha
  // getManifest() ko de deta tha, jo hamesha fail hota — chahe title/
  // author bilkul sahi ho. Ab candidate ID ko pehle verify karte hain;
  // agar invalid nikle to title+author se fresh explode search karke
  // real ID dhoondh lete hain (jaisa Termux test karta hai).
  Future<String> _resolvePlayableVideoId(
    YoutubeExplode yt,
    String candidateId,
    String? title,
    String? author, {
    void Function(String status)? onProgress,
  }) async {
    try {
      await yt.videos.get(candidateId).timeout(const Duration(seconds: 10));
      return candidateId; // valid hai, isi ko use karo
    } catch (e) {
      print('YT id-check: "$candidateId" invalid ($e) — ID kharab nikla');
    }
    if (title == null || title.isEmpty) return candidateId;
    final requery = (author != null && author.isNotEmpty) ? '$title $author' : title;
    onProgress?.call('Video ID galat nikla, "$requery" se real ID dhoond rahe hain...');
    try {
      final results = await yt.search
          .getVideos(requery)
          .timeout(const Duration(seconds: 15));
      if (results.isEmpty) return candidateId;
      final realId = results.first.id.value;
      print('YT id-check: real ID mila: $realId (original: $candidateId)');
      return realId;
    } catch (e) {
      print('YT id-check: fallback search bhi fail: $e');
      return candidateId;
    }
  }

  Future<_AudioStream?> _resolveAudioStream(
    String videoId, {
    void Function(String status)? onProgress,
    String? title,
    String? author,
  }) async {
    var resolvedId = videoId;
    try {
      final yt = await _getYt();
      resolvedId = await _resolvePlayableVideoId(
        yt,
        videoId,
        title,
        author,
        onProgress: onProgress,
      );
    } catch (e) {
      print('YT id-check: skip kiya, error: $e');
    }
    final viaExplode =
        await _audioViaExplode(resolvedId, onProgress: onProgress);
    if (viaExplode != null) return viaExplode;
    return _audioViaPipedBackup(resolvedId, onProgress: onProgress);
  }

  Future<String?> getAudioUrl(
    String videoId, {
    void Function(String status)? onProgress,
    String? title,
    String? author,
  }) async {
    final stream = await _resolveAudioStream(
      videoId,
      onProgress: onProgress,
      title: title,
      author: author,
    );
    return stream?.url;
  }

  // ---------------- Download (permanent, Music/SurSathi/) ----------------

  Future<String?> download(String videoId, String title, {String? author}) async {
    // Storage permission maango (Android 13+ pe scoped, purane pe legacy)
    await Permission.storage.request();
    // Android 13+ pe storage permission zaroori nahi hoti (scoped storage) —
    // isliye request fail ho to bhi aage try karte hain

    final stream =
        await _resolveAudioStream(videoId, title: title, author: author);
    if (stream == null) {
      print('YT DOWNLOAD ERROR: audio stream resolve nahi hua for $videoId');
      return null;
    }

    try {
      final musicDir = await StorageService.getMusicDir();
      final safeName = await StorageService.sanitizeFileName(title);
      final ext = stream.format.isNotEmpty ? stream.format : 'm4a';
      final filePath = p.join(musicDir.path, '$safeName.$ext');

      final request = http.Request('GET', Uri.parse(stream.url));
      final response = await _http.send(request);
      final file = File(filePath);
      final sink = file.openWrite();
      await response.stream.pipe(sink);
      await sink.flush();
      await sink.close();

      // DB me entry daal do taaki Downloads screen turant dikhaye
      await DownloadDB.instance.add(
        Song(
          id: videoId,
          title: stream.title,
          artist: stream.author,
          thumb: stream.thumb,
          duration: stream.duration,
          filePath: filePath,
        ),
      );

      return filePath;
    } catch (e) {
      print('YT DOWNLOAD ERROR: $e');
      return null;
    }
  }

  void dispose() {
    _http.close();
    _yt?.close();
  }
}
