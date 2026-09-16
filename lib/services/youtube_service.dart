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
// yt_music.dart sirf `YTMusic` class export karta hai — SongDetailed/
// VideoDetailed/PlaylistDetailed jaise result types alag `types.dart`
// library me hain, isliye unhe explicitly import karna padta hai
// (varna "isn't a type" compile error aata hai).
import 'package:dart_ytmusic_api/types.dart';
import 'package:newpipeextractor_dart/newpipeextractor_dart.dart' as npe;

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

// Artist search result — naya "Artists" search tab ke liye (dekho search()
// ke saath searchArtists()).
class YtArtistResult {
  final String id;
  final String name;
  final String thumb;

  YtArtistResult({required this.id, required this.name, required this.thumb});
}

// ---------------- Home feed (live/curated — YouTube Music jaisa) ----------------
//
// NEW (2026-09-16, v11): "YouTube Music jaisa live/curated playlist"
// feature. YT Music khud har baar home feed request karne pe naye/
// curated sections deta hai ("Quick picks", "Trending", "Mixed for
// you" wagaira) — isliye "live" hai, koi hardcoded list nahi. Ek
// section ya to seedhe gaano ki list hoti hai (turant play-able) ya
// curated playlists ki list (tap karne pe uske andar ke gaane
// getYtMusicPlaylistTracks() se load hote hain — LiveYtPlaylistScreen
// dekho).

enum YtHomeSectionKind { songs, playlists }

class YtHomeSection {
  final String title;
  final YtHomeSectionKind kind;
  final List<YtResult> songs;
  final List<YtPlaylistPreview> playlists;

  YtHomeSection.songs(this.title, this.songs)
      : kind = YtHomeSectionKind.songs,
        playlists = const [];

  YtHomeSection.playlists(this.title, this.playlists)
      : kind = YtHomeSectionKind.playlists,
        songs = const [];
}

// YT Music curated playlist ka preview card — andar ke gaane tap karne
// pe hi alag se load hote hain (getYtMusicPlaylistTracks).
class YtPlaylistPreview {
  final String id;
  final String title;
  final String subtitle;
  final String thumb;

  YtPlaylistPreview({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.thumb,
  });
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
  Future<YoutubeExplode> _getYt({void Function(String status)? onProgress}) async {
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
      // BUG FIX (2026-09-16, v3): pehle ye sirf print() hoti thi, jo
      // device UI (debug screen) pe kabhi nahi dikhti thi — sirf logcat
      // me. Ab onProgress se bhi bhejte hain taaki debug screen pe pata
      // chale ki Deno solver hi nahi ban paya (common signature-decipher
      // failure ka root cause).
      print('YT: Deno JS solver init nahi hua, bina solver ke aage: $e');
      onProgress?.call('Deno JS solver init FAILED (bina solver aage): $e');
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

  // ---------------- Categorized search (Songs / Artists / Playlists) ----------------
  //
  // NEW: search_screen.dart ab YouTube Music jaisa 3 tabs me results dikhata
  // hai — "Songs" (upar wala search() hi use hota hai), "Artists" aur
  // "Playlists". dart_ytmusic_api ka `searchSongs()` pehle se search() me
  // use ho raha hai aur confirmed kaam karta hai (same package, same
  // `SongDetailed`/`PlaylistDetailed` typed models jo getHomeFeed() me
  // upar use hue hain) — isi convention ke hisaab se `searchArtists()`/
  // `searchPlaylists()` bhi maane gaye hain (dono ke liye field names
  // upar getHomeFeed() ke `PlaylistDetailed` handling se match karte hain:
  // `.playlistId`/`.name`/`.artist.name`/`.thumbnails`). Agar package ka
  // real API thoda alag nikle (naam/field mismatch), dono methods apne
  // try/catch me fail ho ke khaali list dete hain — us tab me sirf "kuch
  // nahi mila" dikhega, baaki app (Songs tab, home feed, playback) is se
  // bilkul unaffected rahega. Dekho NOTES.md.

  Future<List<YtArtistResult>> searchArtists(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      final ytmusic = await _getYtMusic();
      final artists = await ytmusic.searchArtists(query);
      final results = <YtArtistResult>[];
      for (final a in artists) {
        if (a.artistId.isEmpty) continue;
        results.add(YtArtistResult(
          id: a.artistId,
          name: a.name,
          thumb: a.thumbnails.isNotEmpty ? a.thumbnails.last.url : '',
        ));
      }
      return results;
    } catch (e) {
      print('YT MUSIC ARTIST SEARCH ERROR: $e');
      return [];
    }
  }

  Future<List<YtPlaylistPreview>> searchPlaylists(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      final ytmusic = await _getYtMusic();
      final playlists = await ytmusic.searchPlaylists(query);
      final results = <YtPlaylistPreview>[];
      for (final pl in playlists) {
        if (pl.playlistId.isEmpty) continue;
        results.add(YtPlaylistPreview(
          id: pl.playlistId,
          title: pl.name,
          subtitle: pl.artist.name,
          thumb: pl.thumbnails.isNotEmpty ? pl.thumbnails.last.url : '',
        ));
      }
      return results;
    } catch (e) {
      print('YT MUSIC PLAYLIST SEARCH ERROR: $e');
      return [];
    }
  }

  // ---------------- Radio ("current jaisa gaana chalate raho") ----------------
  //
  // NOTE: Ye asli YT Music ka "Radio"/"watch next" continuation feature
  // NAHI hai (uske liye innertube ka private "next" endpoint chahiye, jo
  // yahan available nahi hai — dekho FEATURE_ROADMAP.md #1). Ye ek simple
  // approximation hai: current song ke artist naam se dobara search()
  // karke, current gaana hata ke, baaki ko shuffle karke deta hai. Mini
  // player ke radio button isi list ko queue me "add" karta hai (queue
  // replace nahi karta) taaki abhi chal raha gaana disturb na ho.
  Future<List<Song>> getRadioQueue(
    String seedVideoId,
    String seedTitle,
    String seedArtist, {
    int count = 15,
  }) async {
    try {
      final query = seedArtist.trim().isNotEmpty ? seedArtist.trim() : seedTitle;
      final results = await search(query, max: 30);
      final filtered = results.where((r) => r.id != seedVideoId).toList()
        ..shuffle();
      return filtered.take(count).map((r) => r.toSong()).toList();
    } catch (e) {
      print('RADIO ERROR: $e');
      return [];
    }
  }

  // ---------------- Home feed (live/curated) ----------------

  // YT Music ka poora home feed — "Quick picks"/"Trending"/"Mixed for
  // you" jaise sections, jo YT Music khud curate karta hai aur baar
  // baar refresh karne pe badalte rehte hain. maxSections/
  // maxItemsPerSection isliye hain taaki home screen bahut lamba na ho
  // jaaye. Sections jinme na koi playable song hota hai na koi playlist
  // (jaise "Artists you might like") khud-ba-khud skip ho jaate hain.
  Future<List<YtHomeSection>> getHomeFeed({
    int maxSections = 8,
    int maxItemsPerSection = 12,
  }) async {
    try {
      final ytmusic = await _getYtMusic();
      final raw = await ytmusic.getHomeSections();
      final sections = <YtHomeSection>[];

      for (final section in raw) {
        if (sections.length >= maxSections) break;
        final title = section.title.trim();
        final contents = section.contents;
        if (title.isEmpty || contents.isEmpty) continue;

        final first = contents.first;
        if (first is SongDetailed || first is VideoDetailed) {
          final songs = <YtResult>[];
          for (final item in contents) {
            if (songs.length >= maxItemsPerSection) break;
            String id, name, artist, thumb;
            int duration;
            if (item is SongDetailed) {
              id = item.videoId;
              name = item.name;
              artist = item.artist.name;
              thumb =
                  item.thumbnails.isNotEmpty ? item.thumbnails.last.url : '';
              duration = item.duration ?? 0;
            } else if (item is VideoDetailed) {
              id = item.videoId;
              name = item.name;
              artist = item.artist.name;
              thumb =
                  item.thumbnails.isNotEmpty ? item.thumbnails.last.url : '';
              duration = item.duration ?? 0;
            } else {
              continue;
            }
            if (id.isEmpty) continue;
            songs.add(YtResult(
              id: id,
              title: name,
              author: artist,
              thumb: thumb,
              duration: duration,
            ));
          }
          if (songs.isNotEmpty) sections.add(YtHomeSection.songs(title, songs));
        } else if (first is PlaylistDetailed) {
          final playlists = <YtPlaylistPreview>[];
          for (final item in contents) {
            if (playlists.length >= maxItemsPerSection) break;
            if (item is! PlaylistDetailed) continue;
            if (item.playlistId.isEmpty) continue;
            playlists.add(YtPlaylistPreview(
              id: item.playlistId,
              title: item.name,
              subtitle: item.artist.name,
              thumb:
                  item.thumbnails.isNotEmpty ? item.thumbnails.last.url : '',
            ));
          }
          if (playlists.isNotEmpty) {
            sections.add(YtHomeSection.playlists(title, playlists));
          }
        }
        // AlbumDetailed ya koi aur type wale sections is version me
        // skip hote hain (albums ke liye alag flow chahiye hoga).
      }

      return sections;
    } catch (e) {
      print('YT HOME FEED ERROR: $e');
      return [];
    }
  }

  // Kisi live/curated YT Music playlist ke andar ke gaane — playlist
  // card tap karne pe call hota hai.
  Future<List<YtResult>> getYtMusicPlaylistTracks(String playlistId) async {
    try {
      final ytmusic = await _getYtMusic();
      final videos = await ytmusic.getPlaylistVideos(playlistId);
      return videos
          .where((v) => v.videoId.isNotEmpty)
          .map((v) => YtResult(
                id: v.videoId,
                title: v.name,
                author: v.artist.name,
                thumb: v.thumbnails.isNotEmpty ? v.thumbnails.last.url : '',
                duration: v.duration ?? 0,
              ))
          .toList();
    } catch (e) {
      print('YT MUSIC PLAYLIST TRACKS ERROR ($playlistId): $e');
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
  //
  // BUG FIX: pehle sirf true/false return hota tha — isse "fail hua" to
  // pata chalta tha par "KYUN fail hua" (403 block? timeout? DNS error?)
  // kabhi nahi pata chalta tha, jo asli debugging ke liye sabse zaroori
  // cheez hai. Ab exact status code ya error reason bhi return karte
  // hain, aur onProgress se wo bhi dikhta hai.
  Future<({bool ok, String detail})> _verifyPlayable(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response =
          await request.close().timeout(const Duration(seconds: 6));
      // BUG FIX (2026-09-16): drain<T>() ka T stream ke data ka type NAHI
      // hai — ye us value ka type hai jo function return karta hai (agar
      // kuch na do to default null hota hai). Pehle yahan drain<List<int>>()
      // likha tha, jisse Dart null ko List<int> (non-nullable) me cast
      // karne ki koshish karta tha aur har stream verify pe crash hota
      // tha: "type 'Null' is not a subtype of type 'List<int>' in type
      // cast" — isi wajah se saare audio/muxed streams fail dikh rahe the.
      await response.drain<void>();
      final ok = response.statusCode == 200 || response.statusCode == 206;
      return (ok: ok, detail: 'HTTP ${response.statusCode}');
    } catch (e) {
      print('Stream verify failed: $e');
      return (ok: false, detail: e.toString());
    } finally {
      client?.close(force: true);
    }
  }

  // ---- Layer 1 (PRIMARY, 2026-09-16 v4): NewPipeExtractor ----
  // Ye asli NewPipe app wali extraction hai (Java library, Dart se
  // flutter_inappwebview ke through wrap ki gayi). youtube_explode_dart se
  // zyada reliable hai kyunki NewPipeExtractor ki community bahut badi hai
  // aur YouTube ke changes ke baad zyada tezi se patch aata hai (dekh
  // pubspec.yaml me GPL-3.0 license warning bhi).
  Future<_AudioStream?> _audioViaNewPipe(
    String videoId, {
    void Function(String status)? onProgress,
  }) async {
    final url = 'https://www.youtube.com/watch?v=$videoId';
    try {
      onProgress?.call('Resolving via NewPipeExtractor...');
      final video = await npe.VideoExtractor.getStream(url)
          .timeout(const Duration(seconds: 30));

      final info = video.videoInfo;
      final audio = video.audioWithHighestQuality ??
          (video.audioOnlyStreams.isNotEmpty
              ? video.audioOnlyStreams.first
              : null);
      if (audio == null || audio.url == null || audio.url!.isEmpty) {
        onProgress?.call('NewPipeExtractor: no audio-only stream, trying muxed...');
        final muxed = video.videoStreams.isNotEmpty ? video.videoStreams.first : null;
        if (muxed == null || muxed.url == null || muxed.url!.isEmpty) {
          onProgress?.call('NewPipeExtractor: no usable stream at all');
          return null;
        }
        final v = await _verifyPlayable(muxed.url!);
        onProgress?.call('  -> ${v.ok ? "OK" : "FAIL"} (${v.detail})');
        if (!v.ok) return null;
        return _AudioStream(
          url: muxed.url!,
          format: (muxed.formatSuffix ?? 'mp4').toLowerCase(),
          title: info.name ?? 'Unknown',
          author: info.uploaderName ?? 'Unknown Artist',
          thumb: info.thumbnails.isNotEmpty ? info.thumbnails.last : '',
          duration: info.length ?? 0,
        );
      }

      onProgress?.call('Checking NewPipe audio stream (${audio.averageBitrate}kbps)...');
      final v = await _verifyPlayable(audio.url!);
      onProgress?.call('  -> ${v.ok ? "OK" : "FAIL"} (${v.detail})');
      if (!v.ok) return null;

      return _AudioStream(
        url: audio.url!,
        format: (audio.formatSuffix ?? 'm4a').toLowerCase(),
        title: info.name ?? 'Unknown',
        author: info.uploaderName ?? 'Unknown Artist',
        thumb: info.thumbnails.isNotEmpty ? info.thumbnails.last : '',
        duration: info.length ?? 0,
      );
    } on npe.ExtractorException catch (e) {
      // Har exception type ka apna clear reason hai (README ke mutabik) —
      // isse debug screen pe exact pata chalega, "generic fail" nahi.
      final detail = switch (e) {
        npe.BadUrlException() => 'Invalid URL: ${e.message}',
        npe.FatalFailureException() => 'YouTube API change (fatal): ${e.message}',
        npe.TransientFailureException() => 'YouTube-side temp error: ${e.message}',
        npe.RequestLimitExceededException() => 'Rate limited: ${e.message}',
        npe.ReCaptchaRequiredException() => 'CAPTCHA required at ${e.challengeUrl}',
        npe.StreamIsNullException() => 'No stream available: ${e.message}',
        _ => e.toString(),
      };
      print('NewPipeExtractor failed for $videoId: $detail');
      onProgress?.call('NewPipeExtractor FAILED: $detail');
      return null;
    } catch (e) {
      print('NewPipeExtractor failed (unexpected) for $videoId: $e');
      onProgress?.call('NewPipeExtractor FAILED (unexpected): $e');
      return null;
    }
  }

  // ---- Layer 2: seedha YouTube se (youtube_explode_dart) ----
  Future<_AudioStream?> _audioViaExplode(
    String videoId, {
    void Function(String status)? onProgress,
  }) async {
    try {
      onProgress?.call('Resolving via YouTube...');
      final yt = await _getYt(onProgress: onProgress);

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
      //
      // BUG FIX (2026-09-16, v3): getManifest() ka exception pehle seedha
      // bahar wale catch(e) me chala jaata tha jo sirf print() karta tha
      // (onProgress kabhi nahi bulata tha) — isliye debug screen pe
      // "Resolving via YouTube..." ke turant baad "YouTube direct
      // failed" aa jaata tha, beech ka ASLI error (403? PoToken? no
      // streams? DNS?) kabhi dikhta hi nahi tha. Ab apna try/catch hai
      // jo exact error onProgress se dikhata hai.
      StreamManifest manifest;
      try {
        manifest = await yt.videos.streams
            .getManifest(videoId, ytClients: _ytClients)
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        print('YT explode: getManifest failed for $videoId: $e');
        onProgress?.call('getManifest FAILED: $e');
        return null;
      }

      String fmt(Object container) => container.toString().toLowerCase();

      // Audio-only candidates — sabse high bitrate wale pehle try karo.
      final audioStreams = List.of(manifest.audioOnly)
        ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      for (final s in audioStreams) {
        onProgress?.call('Checking audio stream (${s.bitrate})...');
        final v = await _verifyPlayable(s.url.toString());
        onProgress?.call('  -> ${v.ok ? "OK" : "FAIL"} (${v.detail})');
        if (v.ok) {
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
        final v = await _verifyPlayable(m.url.toString());
        onProgress?.call('  -> ${v.ok ? "OK" : "FAIL"} (${v.detail})');
        if (v.ok) {
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
      onProgress?.call('YouTube direct: sab streams fail (verify se pehle URL mila tha, fetch fail hua)');
      return null;
    } catch (e) {
      // BUG FIX (2026-09-16, v3): ye catch pehle sirf print() karta tha —
      // debug screen pe kabhi nahi dikhta tha kyun explode fail hua
      // (video.get()/getManifest() ke alawa koi aur unexpected exception,
      // jaise YoutubeExplode() init hi fail ho jaye). Ab onProgress se
      // exact error text dikhta hai.
      print('YT explode failed for $videoId: $e');
      onProgress?.call('YouTube direct FAILED (unexpected): $e');
      return null;
    }
  }

  // ---- Layer 3: Piped public instances (BACKUP, free extra try) ----
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
        final v = await _verifyPlayable(url);
        if (!v.ok) {
          print('Piped streams: $base URL bana lekin fetch fail (${v.detail}), trying next');
          onProgress?.call('$base: verify failed (${v.detail}), trying next...');
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
    final viaNewPipe = await _audioViaNewPipe(resolvedId, onProgress: onProgress);
    if (viaNewPipe != null) return viaNewPipe;

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
