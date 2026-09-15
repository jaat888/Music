// lib/services/youtube_service.dart
// YouTube se search, stream URL resolve, aur download karne ka poora kaam.
//
// APPROACH CHANGE (2026-09-16): pehle ye file `youtube_explode_dart` use
// karti thi — jo YouTube ke internal (undocumented) client APIs ko fake
// karke signature deciphering khud karta hai. Ye approach fundamentally
// unstable hai kyunki YouTube jab bhi apna signature/PO-Token logic badalta
// hai, library turant tootne lagti hai (isi wajah se pichhle saare
// "client X try karo, fail ho to Y try karo" jhanjhat wale fixes karne
// pade the).
//
// Ab iski jagah **Piped** (https://github.com/TeamPiped/Piped) use ho raha
// hai — ye ek free, open-source, publicly-hosted proxy hai jo khud YouTube
// ke saath signature/client jhanjhat handle karta hai server-side, aur app
// ko seedha ek simple REST API deta hai (search + stream URLs). Isse:
//   - Koi apna server maintain nahi karna padta (public instances free hain)
//   - App khud koi YouTube client fake nahi karta, isliye YouTube ke
//     client-side changes se seedha break nahi hota
//   - Multiple independent public instances hain — ek down ho to agla
//     try ho jaata hai (same fallback pattern jo pehle clients ke liye
//     tha, ab instances ke liye hai)
//
// Agar future me sab public instances hi down/unreliable ho jayein, to
// apna khud ka Piped instance self-host karna sabse reliable fallback
// hoga — lekin filhaal (free + zero maintenance requirement) public
// instances hi use ho rahe hain.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

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
  final String format; // e.g. "M4A", "WEBM", "OPUS"
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

  // Public Piped instances — order matters, upar wale pehle try hote hain.
  // In sabka apna independent server hai (alag maintainer, alag country),
  // isliye ek saath sab down hone ka chance kaafi kam hai. List
  // https://github.com/TeamPiped/Piped/wiki/Instances se li gayi hai —
  // agar koi instance permanently band ho jaye, is list ko wahan se
  // refresh kar lena.
  static const List<String> _instances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.leptons.xyz',
    'https://pipedapi.nosebs.ru',
    'https://pipedapi-libre.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://api.piped.yt',
    'https://pipedapi.drgns.space',
  ];

  final http.Client _http = http.Client();

  // ---------------- Search ----------------

  Future<List<YtResult>> search(
    String query, {
    int max = 30,
    void Function(String status)? onProgress,
  }) async {
    if (query.trim().isEmpty) return [];

    for (final base in _instances) {
      onProgress?.call('Trying $base...');
      try {
        final uri = Uri.parse('$base/search').replace(queryParameters: {
          'q': query,
          'filter': 'music_songs',
        });
        final res = await _http.get(uri).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) {
          print('Piped search: $base returned ${res.statusCode}, trying next');
          onProgress?.call('$base: HTTP ${res.statusCode}, trying next...');
          continue;
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final items = (data['items'] as List?) ?? [];
        final results = <YtResult>[];

        for (final it in items) {
          if (results.length >= max) break;
          try {
            final result = _itemToResult(it as Map<String, dynamic>);
            if (result != null) results.add(result);
          } catch (e) {
            // Ek item ka shape kharaab ho to sirf usse skip karo, poora
            // search crash na ho (same protection jo pehle bhi thi)
            print('Piped search: 1 item skip kiya (bad shape): $e');
            continue;
          }
        }

        if (results.isNotEmpty) {
          onProgress?.call('$base: OK, ${results.length} results');
          return results;
        }
        // Khaali results — YouTube pe genuinely kuch na mila ho sakta hai,
        // lekin agle instance pe bhi try kar lo, kabhi ek instance ka
        // index stale/incomplete hota hai
        print('Piped search: $base returned 0 results, trying next');
        onProgress?.call('$base: 0 results, trying next...');
        continue;
      } catch (e) {
        print('Piped search: $base failed: $e');
        onProgress?.call('$base: error, trying next...');
        continue;
      }
    }
    print('YT SEARCH ERROR: saare Piped instances fail ho gaye');
    onProgress?.call('All instances failed.');
    return [];
  }

  // ---------------- Playlist ----------------

  Future<List<YtResult>> getPlaylist(String playlistId) async {
    for (final base in _instances) {
      try {
        final uri = Uri.parse('$base/playlists/$playlistId');
        final res = await _http.get(uri).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final items = (data['relatedStreams'] as List?) ?? [];
        final results = <YtResult>[];

        for (final it in items) {
          try {
            final result = _itemToResult(it as Map<String, dynamic>);
            if (result != null) results.add(result);
          } catch (e) {
            print('Piped playlist: 1 item skip kiya (bad shape): $e');
            continue;
          }
        }
        if (results.isNotEmpty) return results;
        continue;
      } catch (e) {
        print('Piped playlist: $base failed: $e');
        continue;
      }
    }
    print('YT PLAYLIST ERROR: saare Piped instances fail ho gaye for $playlistId');
    return [];
  }

  // Search/playlist item (Piped ka raw JSON shape) ko YtResult me convert
  // karta hai. `url` field "/watch?v=xxxxxxxxxxx" jaisa hota hai.
  YtResult? _itemToResult(Map<String, dynamic> it) {
    final rawUrl = it['url'] as String?;
    if (rawUrl == null) return null;

    final id = Uri.parse(rawUrl).queryParameters['v'];
    if (id == null || id.isEmpty) return null;

    return YtResult(
      id: id,
      title: (it['title'] as String?) ?? 'Unknown',
      author: (it['uploaderName'] as String?) ?? 'Unknown Artist',
      thumb: (it['thumbnail'] as String?) ?? '',
      duration: (it['duration'] as num?)?.toInt() ?? 0,
    );
  }

  // ---------------- Audio stream resolve (streaming/download dono ke liye) ----------------

  // Har candidate URL ko ek chhota real HTTP range-request (~1KB) bhejke
  // verify karte hain ki asal me fetch ho pa raha hai ya nahi. Piped ke
  // audio URLs kabhi self-hosted CDN ke, kabhi seedha googlevideo.com pe
  // redirect karte hain — dono jagah expired/invalid URL mil sakta hai,
  // isliye "URL mila" aur "URL actually chalta hai" alag check hain.
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

  // Instances ko ek-ek karke try karta hai jab tak koi *real playable*
  // audio stream na mil jaye.
  Future<_AudioStream?> _resolveAudioStream(
    String videoId, {
    void Function(String status)? onProgress,
  }) async {
    for (final base in _instances) {
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

        // Highest bitrate wala audio stream chuno
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
          format: ((best['format'] as String?) ?? 'M4A').toLowerCase(),
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
    print('YT AUDIO URL ERROR: saare Piped instances fail ho gaye for $videoId');
    onProgress?.call('All instances failed.');
    return null;
  }

  Future<String?> getAudioUrl(
    String videoId, {
    void Function(String status)? onProgress,
  }) async {
    final stream = await _resolveAudioStream(videoId, onProgress: onProgress);
    return stream?.url;
  }

  // ---------------- Download (permanent, Music/SurSathi/) ----------------

  Future<String?> download(String videoId, String title) async {
    // Storage permission maango (Android 13+ pe scoped, purane pe legacy)
    await Permission.storage.request();
    // Android 13+ pe storage permission zaroori nahi hoti (scoped storage) —
    // isliye request fail ho to bhi aage try karte hain

    final stream = await _resolveAudioStream(videoId);
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
  }
}
