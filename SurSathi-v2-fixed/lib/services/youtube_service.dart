// lib/services/youtube_service.dart
// YouTube se search, stream URL resolve, aur download karne ka poora kaam.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

class YoutubeService {
  YoutubeService._internal();
  static final YoutubeService instance = YoutubeService._internal();

  final YoutubeExplode _yt = YoutubeExplode();

  // Alag-alag YouTube clients — ek block/403 ho jaye to doosra try hota hai.
  //
  // VERSION NOTE (youtube_explode_dart 3.1.0 ke hisaab se valid clients):
  //   YoutubeApiClient.androidSdkless  — Android client, androidSdkVersion
  //                                      field NAHI bhejta. Ye field YouTube
  //                                      ka PO-Token check trigger karta
  //                                      hai jo audio-only streams pe 403
  //                                      deta hai (Feb 2026 me library me
  //                                      fix hua, PR #371). ISLIYE PEHLA
  //                                      TRY YAHI HONA CHAHIYE.
  //   YoutubeApiClient.androidVr       — high quality, VR client, reliable
  //   YoutubeApiClient.ios             — signature deciphering nahi maangta
  //   YoutubeApiClient.android         — purana android client (SDK version
  //                                      wala) — androidSdkless fail ho to
  //                                      hi fallback ke taur pe
  //   YoutubeApiClient.mweb            — mobile web, kabhi-kabhi low quality
  //
  // `.web` naam ka koi client is version me nahi hai (isliye list me nahi
  // hai) — agar future version me `YoutubeApiClient.` type karke IDE
  // autocomplete check karoge to jo bhi naye/renamed clients dikhein unko
  // yahan add/remove kar sakte ho.
  static final List<YoutubeApiClient> _clients = [
    YoutubeApiClient.androidSdkless,
    YoutubeApiClient.androidVr,
    YoutubeApiClient.ios,
    YoutubeApiClient.android,
    YoutubeApiClient.mweb,
  ];

  // ---------------- Search ----------------

  Future<List<YtResult>> search(String query, {int max = 30}) async {
    if (query.trim().isEmpty) return [];

    try {
      final searchList = await _yt.search.search(query);
      final results = <YtResult>[];

      for (final video in searchList) {
        if (results.length >= max) break;
        // BUG FIX: pehle yahan try-catch nahi tha. Generic queries
        // (jaise 'bollywood hits songs') ke results me kabhi-kabhi
        // YouTube ek Mix/playlist-jaisa item bhi de deta hai jiska
        // shape normal Video jaisa nahi hota — .duration ya .thumbnails
        // access karte hi exception aata tha, aur wo EK item poore
        // loop ko crash kar deta, isliye saare achhe results bhi
        // discard ho jaate the (isliye 'arijit singh' jaisi specific
        // query debug screen pe chal jaati thi, par generic queries
        // Home/Search pe khaali aati thi). Ab sirf wo ek item skip
        // hoga, baaki results bach jayenge.
        try {
          results.add(_videoToResult(video));
        } catch (e) {
          print('YT SEARCH: 1 item skip kiya (bad shape): $e');
          continue;
        }
      }
      return results;
    } catch (e) {
      // Search fail hua (network/parsing issue) — khali list return karo,
      // UI empty-state dikha dega. Error console me print karo taaki
      // `adb logcat` ya debug screen se pata chal sake kya hua.
      print('YT SEARCH ERROR: $e');
      return [];
    }
  }

  // ---------------- Playlist ----------------

  Future<List<YtResult>> getPlaylist(String playlistId) async {
    try {
      final videos = await _yt.playlists.getVideos(playlistId).toList();
      final results = <YtResult>[];
      for (final video in videos) {
        try {
          results.add(_videoToResult(video));
        } catch (e) {
          print('YT PLAYLIST: 1 item skip kiya (bad shape): $e');
          continue;
        }
      }
      return results;
    } catch (e) {
      print('YT PLAYLIST ERROR: $e');
      return [];
    }
  }

  YtResult _videoToResult(dynamic video) {
    final thumbUrl = video.thumbnails.highResUrl.isNotEmpty
        ? video.thumbnails.highResUrl as String
        : video.thumbnails.standardResUrl as String;

    return YtResult(
      id: video.id.value as String,
      title: video.title as String,
      author: video.author as String,
      thumb: thumbUrl,
      duration: (video.duration?.inSeconds ?? 0) as int,
    );
  }

  // ---------------- Audio URL resolve (streaming ke liye) ----------------

  // Clients ko ek-ek karke try karta hai jab tak koi audio stream na mil jaye
  Future<String?> getAudioUrl(String videoId) async {
    for (final client in _clients) {
      try {
        // BUG FIX: pehle koi timeout nahi tha — agar network slow/stuck ho
        // to ek client ka getManifest() call kabhi khatam hi nahi hota tha,
        // aur poora playWithRetry() loop (isliye poora "play" tap) waheen
        // atka reh jaata tha, koi error/fallback trigger hue bina. Ab 10s
        // ke baad wo client fail maan ke agla try hota hai.
        final manifest = await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [client])
            .timeout(const Duration(seconds: 10));
        if (manifest.audioOnly.isEmpty) {
          print('Client $client: audioOnly empty, trying next');
          continue;
        }

        final best = manifest.audioOnly.withHighestBitrate();
        return best.url.toString();
      } catch (e) {
        // Is client se nahi mila — agla client try karo
        print('Client $client failed: $e');
        continue;
      }
    }
    print('YT AUDIO URL ERROR: saare clients fail ho gaye for $videoId');
    return null; // saare clients fail ho gaye
  }

  // ---------------- Download (permanent, Music/SurSathi/) ----------------

  Future<String?> download(String videoId, String title) async {
    // Storage permission maango (Android 13+ pe scoped, purane pe legacy)
    final status = await Permission.storage.request();
    if (!status.isGranted) {
      // Android 13+ pe storage permission zaroori nahi hoti (scoped storage) —
      // isliye request fail ho to bhi aage try karte hain
    }

    for (final client in _clients) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );
        if (manifest.audioOnly.isEmpty) {
          print('Client $client (download): audioOnly empty, trying next');
          continue;
        }

        final streamInfo = manifest.audioOnly.withHighestBitrate();
        final musicDir = await StorageService.getMusicDir();
        final safeName = await StorageService.sanitizeFileName(title);
        final ext = streamInfo.container.name;
        final filePath = p.join(musicDir.path, '$safeName.$ext');

        final file = File(filePath);
        final sink = file.openWrite();
        final stream = _yt.videos.streamsClient.get(streamInfo);
        await sink.addStream(stream);
        await sink.flush();
        await sink.close();

        // DB me entry daal do taaki Downloads screen turant dikhaye
        final video = await _yt.videos.get(videoId);
        final result = _videoToResult(video);
        await DownloadDB.instance.add(
          result.toSong().copyWith(filePath: filePath),
        );

        return filePath;
      } catch (e) {
        print('Client $client (download) failed: $e');
        continue; // is client se download fail — agla try karo
      }
    }
    print('YT DOWNLOAD ERROR: saare clients fail ho gaye for $videoId');
    return null; // saare clients fail
  }

  void dispose() {
    _yt.close();
  }
}
