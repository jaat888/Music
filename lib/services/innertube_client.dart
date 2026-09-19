// lib/services/innertube_client.dart
//
// NEW (2026-09-16, v18): apna khud ka, typed, Dart-native YouTube Music
// "InnerTube" client — OpenTune (github.com/Arturo254/OpenTune) ke pattern
// se copy nahi, sirf APPROACH se inspire hoke likha gaya hai (unka code
// Kotlin hai, ye poora naya Dart implementation hai, http/dio jaisa plain
// package use karke). InnerTube khud koi secret/proprietary protocol nahi
// hai — sirf ek HTTP+JSON endpoint hai jo music.youtube.com ki website khud
// browser se call karti hai; dart_ytmusic_api, ytmusicapi (Python),
// youtube-music-desktop-app, OpenTune — sab isi endpoint ko alag-alag
// languages me wrap karte hain. Ye file wahi cheez seedha Dart me karti hai,
// taaki:
//   1. Pagination/continuation token properly mile (dart_ytmusic_api isko
//      expose nahi karta — FEATURE_ROADMAP.md #1 ka root cause).
//   2. Ek hi single typed source ho (3 fallback libraries ka alag-alag data
//      shape na jhelna pade) — playlist/search crash-surface kam ho.
//
// IMPORTANT — reliability note: ye reverse-engineered (undocumented) endpoint
// hai, YouTube ka koi official public API nahi. Isliye har jagah defensive
// parsing (koi bhi field missing/shape-mismatch ho to us item ko sirf skip
// karo, poora call fail mat karo) aur try/catch — jaisa poore codebase ka
// convention hai (dekho youtube_service.dart). Agar YouTube apna internal
// JSON shape badal de, sirf is ek file ko patch karna padega; baaki app
// (existing dart_ytmusic_api / youtube_explode_dart layers) fallback ki
// tarah already maujood hai — koi hard dependency sirf isi client pe nahi
// hai.
//
// Config (client name/version/key) wahi public values hain jo YT Music ki
// khud ki website (music.youtube.com) browser me use karti hai aur jo
// dart_ytmusic_api/ytmusicapi jaisi open-source libraries me bhi documented
// hain — koi private/leaked credential nahi.

import 'dart:convert';

import 'package:http/http.dart' as http;

// ---------------- Lightweight result models ----------------

class InnertubeSong {
  final String id;
  final String title;
  final String author;
  final String thumb;
  final int duration; // seconds

  InnertubeSong({
    required this.id,
    required this.title,
    required this.author,
    required this.thumb,
    required this.duration,
  });
}

class InnertubeArtist {
  final String id;
  final String name;
  final String thumb;

  InnertubeArtist({required this.id, required this.name, required this.thumb});
}

class InnertubePlaylistPreview {
  final String id;
  final String title;
  final String subtitle;
  final String thumb;

  InnertubePlaylistPreview({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.thumb,
  });
}

// Ek "page" of results + agla page laane ke liye continuation token
// (null continuation = aur page nahi bache, list yahi khatam).
class InnertubePage<T> {
  final List<T> items;
  final String? continuation;

  InnertubePage(this.items, this.continuation);

  static InnertubePage<T> empty<T>() => InnertubePage<T>([], null);
}

class InnertubeMoodCategory {
  final String title;
  final String params;
  final String section;

  InnertubeMoodCategory({
    required this.title,
    required this.params,
    required this.section,
  });
}

// ---------------- The client ----------------

class InnertubeClient {
  InnertubeClient._internal();
  static final InnertubeClient instance = InnertubeClient._internal();

  static const String _baseUrl = 'https://music.youtube.com/youtubei/v1';

  // Public WEB_REMIX innertube key — YT Music website khud isko browser
  // requests me bhejti hai, koi private secret nahi (ytmusicapi jaisi
  // open-source libraries me bhi yahi key hardcoded milegi). Ye sirf
  // STARTING default hai — agar ye kabhi reject ho jaye (YouTube ne
  // rotate kar diya), `_refreshConfig()` isko live music.youtube.com HTML
  // se replace kar deta hai (dekho niche) — ArchiveTune/ytmusicapi jaisi
  // libraries bhi yahi self-heal pattern use karti hain, sirf hardcoded
  // pe bharosa nahi karti.
  static const String _defaultApiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const String _defaultClientVersion = '1.20241201.01.00';

  String _apiKey = _defaultApiKey;
  String _clientVersion = _defaultClientVersion;
  bool _refreshedConfigOnce = false;

  // Music-specific search filters ("params" field) — YT Music website in
  // exact values ko search request me bhejti hai jab user "Songs" /
  // "Artists" / "Playlists" tab select karta hai. Agar YouTube ye values
  // kal badal de to us specific tab ka result khaali aa sakta hai — us
  // case me caller (youtube_service.dart) already fallback (dart_ytmusic_api
  // ya generic search) pe chala jaata hai, poori app crash nahi hoti.
  static const String _filterSongs = 'EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D';
  static const String _filterArtists = 'EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D';
  static const String _filterPlaylists = 'EgWKAQIoAWoKEAMQBBAJEAoQBQ%3D%3D';

  final http.Client _http = http.Client();

  Map<String, dynamic> get _context => {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _clientVersion,
            'hl': 'en',
            'gl': 'US',
          },
        },
      };

  Uri _endpoint(String name) =>
      Uri.parse('$_baseUrl/$name?key=$_apiKey&prettyPrint=false');

  // BUG FIX (2026-09-16, Batch 21 — "search me purane/generic gaane"
  // continue hone ka ek aur possible root cause): pehle _refreshConfig()
  // sirf REACTIVE tha — sirf tab chalta tha jab request 400/403 se fail ho
  // jaaye. Lekin agar YouTube kisi stale clientVersion ko seedha reject
  // (400/403) nahi karta, balki bas ALAG/kam-accurate (generic, non-music-
  // ranked) results 200 OK ke saath de deta hai — jo iske hardcoded
  // default (`1.20241201.01.00`, ~21 mahine purana) ke saath bilkul ho
  // sakta hai — to self-heal kabhi trigger hi nahi hota, aur "purane
  // gaane" wali complaint bina kisi error/signal ke chalti rehti. Real
  // YT Music clients (OpenTune/OuterTune jaisi Kotlin apps) is risk se
  // bachte hain kyunki unka innertube module actively maintained hota hai
  // (dependency-bot se regularly update). Yahan wo possible nahi (koi
  // build-time codegen nahi), isliye PROACTIVE bana diya: pehli hi call
  // pe (chahe wo successful ho ya fail), config ek baar zaroor refresh ho
  // jaata hai — taaki purane hardcoded default pe kabhi bharosa na karna
  // pade, bina kisi error ka wait kiye.
  //
  // SELF-HEAL (v20): agar hardcoded key/version kabhi stale ho jaaye,
  // seedha music.youtube.com ke HTML se live values nikal lete hain — jaisa
  // ytmusicapi/OpenTune jaisi libraries khud karti hain. Sirf EK baar
  // try hota hai per app-session (_refreshedConfigOnce) — baar baar
  // music.youtube.com ki poori HTML download karna mehenga hai, aur agar
  // ye bhi fail ho gaya to matlab network hi down hai, dobara try karne se
  // kuch nahi badlega (us case me existing fallback layers sambhal lenge).
  Future<bool> _refreshConfig() async {
    if (_refreshedConfigOnce) return false;
    _refreshedConfigOnce = true;
    try {
      final res = await _http
          .get(Uri.parse('https://music.youtube.com'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;
      final html = res.body;

      final keyMatch =
          RegExp(r'"INNERTUBE_API_KEY":"([^"]{20,50})"').firstMatch(html);
      final verMatch = RegExp(r'"INNERTUBE_CLIENT_VERSION":"([^"]+)"')
          .firstMatch(html);

      var changed = false;
      if (keyMatch != null) {
        _apiKey = keyMatch.group(1)!;
        changed = true;
      }
      if (verMatch != null) {
        _clientVersion = verMatch.group(1)!;
        changed = true;
      }
      if (changed) {
        print('INNERTUBE: config refreshed from music.youtube.com HTML');
      }
      return changed;
    } catch (e) {
      print('INNERTUBE config refresh FAILED: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> _post(
    String endpoint,
    Map<String, dynamic> extraBody, {
    bool isRetry = false,
  }) async {
    // Proactive refresh (dekho _refreshConfig() ka comment) — session ki
    // pehli hi call se pehle ek baar zaroor try karo, error ka wait mat
    // karo. `_refreshConfig()` khud `_refreshedConfigOnce` se guarded hai,
    // isliye ye har request pe dobara HTML download nahi karega.
    if (!isRetry) await _refreshConfig();
    try {
      final body = {..._context, ...extraBody};
      final res = await _http
          .post(
            _endpoint(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Format-Version': '1',
              'Origin': 'https://music.youtube.com',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        print('INNERTUBE $endpoint: HTTP ${res.statusCode}');
        // Key/version stale hone ka classic sign 400/403 hota hai — ek
        // baar live config refresh karke retry karo (dekho _refreshConfig).
        if (!isRetry &&
            (res.statusCode == 400 || res.statusCode == 403) &&
            await _refreshConfig()) {
          return _post(endpoint, extraBody, isRetry: true);
        }
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (e) {
      print('INNERTUBE $endpoint FAILED: $e');
      return null;
    }
  }

  // ---------------- Generic recursive JSON helpers ----------------
  //
  // YouTube ka internal JSON deeply/inconsistently nested hota hai aur
  // beech-beech me shape badal deta hai. Exact fixed path likhne ke bajaye
  // (jo ek chhoti tabdeeli pe hi crash ho jaata), poore tree me recursively
  // dhoondte hain — jo bhi mile wahi use karo, jo na mile use skip karo.

  // Tree me har jagah dhoondo jahan `key` naam ka field maujood ho, aur
  // us field ki value collect karo (chahe wo kitni bhi neeche nested ho).
  void _collect(dynamic node, String key, List<dynamic> out) {
    if (node is Map) {
      node.forEach((k, v) {
        if (k == key) out.add(v);
        _collect(v, key, out);
      });
    } else if (node is List) {
      for (final item in node) {
        _collect(item, key, out);
      }
    }
  }

  List<dynamic> _findAll(dynamic node, String key) {
    final out = <dynamic>[];
    _collect(node, key, out);
    return out;
  }

  // Continuation token dhoondo — do jagah aa sakta hai: purana style
  // (`nextContinuationData.continuation`) ya naya style
  // (`continuationEndpoint.continuationCommand.token`, jo
  // `continuationItemRenderer` ke andar hota hai).
  String? _findContinuationToken(dynamic node) {
    for (final c in _findAll(node, 'nextContinuationData')) {
      if (c is Map && c['continuation'] is String) {
        return c['continuation'] as String;
      }
    }
    for (final c in _findAll(node, 'continuationCommand')) {
      if (c is Map && c['token'] is String) {
        return c['token'] as String;
      }
    }
    // Radio/"watch next" continuation (playlistPanelRenderer) alag shape
    // use karta hai: {"playlistPanelContinuation": {"continuation": "..."}}
    for (final c in _findAll(node, 'playlistPanelContinuation')) {
      if (c is Map && c['continuation'] is String) {
        return c['continuation'] as String;
      }
    }
    return null;
  }

  String _runsText(dynamic flexColumn) {
    try {
      final runs = flexColumn['musicResponsiveListItemFlexColumnRenderer']
          ['text']['runs'] as List;
      return runs.map((r) => r['text'] as String? ?? '').join();
    } catch (_) {
      return '';
    }
  }

  String _bestThumb(dynamic item) {
    try {
      final thumbs = item['thumbnail']['musicThumbnailRenderer']['thumbnail']
          ['thumbnails'] as List;
      if (thumbs.isEmpty) return '';
      return thumbs.last['url'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  String? _watchVideoId(dynamic item) {
    try {
      final id = item['playlistItemData']?['videoId'];
      if (id is String && id.isNotEmpty) return id;
    } catch (_) {}
    try {
      final overlays = item['overlay']?['musicItemThumbnailOverlayRenderer']
          ?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']
              ?['watchEndpoint']?['videoId'];
      if (overlays is String && overlays.isNotEmpty) return overlays;
    } catch (_) {}
    try {
      final id = item['navigationEndpoint']?['watchEndpoint']?['videoId'];
      if (id is String && id.isNotEmpty) return id;
    } catch (_) {}
    return null;
  }

  String? _browseId(dynamic item) {
    try {
      final id = item['navigationEndpoint']?['browseEndpoint']?['browseId'];
      if (id is String && id.isNotEmpty) return id;
    } catch (_) {}
    return null;
  }

  // "3:45" ya "1:02:03" jaisi duration text ko seconds me convert karta hai.
  int _parseDurationText(String text) {
    final parts = text.trim().split(':');
    if (parts.isEmpty) return 0;
    try {
      var seconds = 0;
      for (final p in parts) {
        seconds = seconds * 60 + int.parse(p);
      }
      return seconds;
    } catch (_) {
      return 0;
    }
  }

  int _findDuration(dynamic item) {
    // Flex columns ke aखिri runs me kabhi-kabhi duration text hota hai.
    try {
      final flexColumns = item['flexColumns'] as List;
      for (final col in flexColumns.reversed) {
        final text = _runsText(col);
        if (RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim())) {
          return _parseDurationText(text.trim());
        }
      }
    } catch (_) {}
    // Fixed column (kuch layouts me duration alag se yahan hoti hai).
    try {
      final fixed = item['fixedColumns'] as List;
      for (final col in fixed) {
        final text = _runsText(col);
        if (RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim())) {
          return _parseDurationText(text.trim());
        }
      }
    } catch (_) {}
    return 0;
  }

  InnertubeSong? _songFromItem(dynamic item) {
    try {
      final videoId = _watchVideoId(item);
      if (videoId == null || videoId.isEmpty) return null;
      final flexColumns = item['flexColumns'] as List;
      final title = flexColumns.isNotEmpty ? _runsText(flexColumns[0]) : '';
      if (title.isEmpty) return null;
      var author = '';
      if (flexColumns.length > 1) {
        author = _runsText(flexColumns[1])
            .split('•')
            .map((s) => s.trim())
            .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      }
      return InnertubeSong(
        id: videoId,
        title: title,
        author: author,
        thumb: _bestThumb(item),
        duration: _findDuration(item),
      );
    } catch (_) {
      return null;
    }
  }

  InnertubeArtist? _artistFromItem(dynamic item) {
    try {
      final browseId = _browseId(item);
      if (browseId == null || browseId.isEmpty) return null;
      final flexColumns = item['flexColumns'] as List;
      final name = flexColumns.isNotEmpty ? _runsText(flexColumns[0]) : '';
      if (name.isEmpty) return null;
      return InnertubeArtist(id: browseId, name: name, thumb: _bestThumb(item));
    } catch (_) {
      return null;
    }
  }

  InnertubePlaylistPreview? _playlistFromTwoRowItem(dynamic item) {
    try {
      var browseId;
      final titleRuns = item['title']?['runs'] as List?;
      if (titleRuns != null && titleRuns.isNotEmpty) {
        browseId = titleRuns.first['navigationEndpoint']?['browseEndpoint']?['browseId'];
      }
      browseId ??= item['navigationEndpoint']?['browseEndpoint']?['browseId'];
      if (browseId is! String || browseId.isEmpty) return null;
      if (browseId.startsWith('VL')) browseId = browseId.substring(2);
      final title = titleRuns != null
          ? titleRuns.map((r) => r['text'] as String? ?? '').join()
          : '';
      if (title.trim().isEmpty) return null;
      final subtitleRuns = item['subtitle']?['runs'] as List?;
      final subtitle = subtitleRuns != null
          ? subtitleRuns.map((r) => r['text'] as String? ?? '').join()
          : '';
      var thumb = '';
      final thumbs = item['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
      if (thumbs != null && thumbs.isNotEmpty) {
        thumb = thumbs.last['url'] as String? ?? '';
      }
      return InnertubePlaylistPreview(
        id: browseId,
        title: title.trim(),
        subtitle: subtitle.trim(),
        thumb: thumb,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------- Moods & Genres ----------------

  Future<List<InnertubeMoodCategory>> moodCategories() async {
    final data = await _post('browse', {'browseId': 'FEmusic_moods_and_genres'});
    if (data == null) return const [];

    final results = <InnertubeMoodCategory>[];
    final seen = <String>{};
    for (final grid in _findAll(data, 'gridRenderer')) {
      if (grid is! Map) continue;
      final titleText = grid['header']?['gridHeaderRenderer']?['title']?['runs'];
      final section = titleText is List
          ? titleText.map((r) => r['text'] as String? ?? '').join().trim()
          : '';
      final items = grid['items'];
      if (items is! List) continue;
      for (final raw in items) {
        if (raw is! Map) continue;
        final button = raw['musicNavigationButtonRenderer'] is Map
            ? raw['musicNavigationButtonRenderer']
            : raw;
        final buttonText = button['buttonText']?['runs'];
        final title = buttonText is List
            ? buttonText.map((r) => r['text'] as String? ?? '').join().trim()
            : '';
        final params = button['clickCommand']?['browseEndpoint']?['params'];
        if (title.isEmpty || params is! String || params.isEmpty) continue;
        final key = '$title|$params';
        if (seen.add(key)) {
          results.add(InnertubeMoodCategory(
            title: title,
            params: params,
            section: section,
          ));
        }
      }
    }
    return results;
  }

  Future<InnertubePage<InnertubePlaylistPreview>> moodPlaylists(
    String params, {
    String? continuation,
  }) async {
    final data = continuation != null
        ? await _post('browse', {'continuation': continuation})
        : await _post('browse', {
            'browseId': 'FEmusic_moods_and_genres_category',
            'params': params,
          });
    if (data == null) {
      return InnertubePage.empty<InnertubePlaylistPreview>();
    }

    final results = <InnertubePlaylistPreview>[];
    final seen = <String>{};
    for (final raw in _findAll(data, 'musicTwoRowItemRenderer')) {
      final playlist = _playlistFromTwoRowItem(raw);
      if (playlist != null && seen.add(playlist.id)) results.add(playlist);
    }
    // Some experiments/layouts render the category as responsive list items.
    for (final raw in _findAll(data, 'musicResponsiveListItemRenderer')) {
      final playlist = _playlistFromItem(raw);
      if (playlist != null && seen.add(playlist.id)) results.add(playlist);
    }

    return InnertubePage<InnertubePlaylistPreview>(
      results,
      _findContinuationToken(data),
    );
  }

  InnertubePlaylistPreview? _playlistFromItem(dynamic item) {
    try {
      var browseId = _browseId(item);
      if (browseId == null || browseId.isEmpty) return null;
      if (browseId.startsWith('VL')) browseId = browseId.substring(2);
      final flexColumns = item['flexColumns'] as List;
      final title = flexColumns.isNotEmpty ? _runsText(flexColumns[0]) : '';
      if (title.isEmpty) return null;
      final subtitle = flexColumns.length > 1 ? _runsText(flexColumns[1]) : '';
      return InnertubePlaylistPreview(
        id: browseId,
        title: title,
        subtitle: subtitle,
        thumb: _bestThumb(item),
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------- Search ----------------

  Future<Map<String, dynamic>?> _runSearchRaw(
    String query,
    String filterParams, {
    String? continuation,
  }) async {
    if (continuation != null) {
      return _post('search', {'continuation': continuation});
    }
    return _post('search', {'query': query, 'params': filterParams});
  }

  Future<InnertubePage<InnertubeSong>> searchSongs(
    String query, {
    String? continuation,
  }) async {
    final data =
        await _runSearchRaw(query, _filterSongs, continuation: continuation);
    if (data == null) return InnertubePage.empty<InnertubeSong>();
    final rawItems = _findAll(data, 'musicResponsiveListItemRenderer');
    final results = <InnertubeSong>[];
    for (final raw in rawItems) {
      final song = _songFromItem(raw);
      if (song != null) results.add(song);
    }
    final nextToken = _findContinuationToken(data);
    return InnertubePage<InnertubeSong>(results, nextToken);
  }

  Future<InnertubePage<InnertubeArtist>> searchArtists(
    String query, {
    String? continuation,
  }) async {
    final data = await _runSearchRaw(query, _filterArtists,
        continuation: continuation);
    if (data == null) return InnertubePage.empty<InnertubeArtist>();
    final rawItems = _findAll(data, 'musicResponsiveListItemRenderer');
    final results = <InnertubeArtist>[];
    for (final raw in rawItems) {
      final artist = _artistFromItem(raw);
      if (artist != null) results.add(artist);
    }
    final nextToken = _findContinuationToken(data);
    return InnertubePage<InnertubeArtist>(results, nextToken);
  }

  Future<InnertubePage<InnertubePlaylistPreview>> searchPlaylists(
    String query, {
    String? continuation,
  }) async {
    final data = await _runSearchRaw(query, _filterPlaylists,
        continuation: continuation);
    if (data == null) return InnertubePage.empty<InnertubePlaylistPreview>();
    final rawItems = _findAll(data, 'musicResponsiveListItemRenderer');
    final results = <InnertubePlaylistPreview>[];
    for (final raw in rawItems) {
      final pl = _playlistFromItem(raw);
      if (pl != null) results.add(pl);
    }
    final nextToken = _findContinuationToken(data);
    return InnertubePage<InnertubePlaylistPreview>(results, nextToken);
  }

  // ---------------- Playlist tracks (browse) ----------------

  Future<InnertubePage<InnertubeSong>> playlistTracks(
    String playlistId, {
    String? continuation,
  }) async {
    Map<String, dynamic>? data;
    if (continuation != null) {
      data = await _post('browse', {'continuation': continuation});
    } else {
      final browseId =
          playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
      data = await _post('browse', {'browseId': browseId});
    }
    if (data == null) return InnertubePage.empty<InnertubeSong>();
    final rawItems = _findAll(data, 'musicResponsiveListItemRenderer');
    final results = <InnertubeSong>[];
    for (final raw in rawItems) {
      final song = _songFromItem(raw);
      if (song != null) results.add(song);
    }
    final nextToken = _findContinuationToken(data);
    return InnertubePage<InnertubeSong>(results, nextToken);
  }

  // Radio/"watch next" (`playlistPanelVideoRenderer`) ka shape search/browse
  // ke `musicResponsiveListItemRenderer` se alag hai — apna extractor.
  InnertubeSong? _songFromPanelItem(dynamic item) {
    try {
      String? videoId = item['videoId'] as String?;
      videoId ??=
          item['navigationEndpoint']?['watchEndpoint']?['videoId'] as String?;
      if (videoId == null || videoId.isEmpty) return null;

      final titleRuns = item['title']?['runs'] as List?;
      final title = titleRuns != null
          ? titleRuns.map((r) => r['text'] as String? ?? '').join()
          : '';
      if (title.isEmpty) return null;

      final bylineRuns = (item['longBylineText']?['runs'] ??
          item['shortBylineText']?['runs']) as List?;
      var author = '';
      if (bylineRuns != null && bylineRuns.isNotEmpty) {
        author = (bylineRuns.first['text'] as String? ?? '').trim();
      }

      final lengthRuns = item['lengthText']?['runs'] as List?;
      final durationText = lengthRuns != null
          ? lengthRuns.map((r) => r['text'] as String? ?? '').join()
          : '';

      final thumbs = item['thumbnail']?['thumbnails'] as List?;
      final thumb = (thumbs != null && thumbs.isNotEmpty)
          ? (thumbs.last['url'] as String? ?? '')
          : '';

      return InnertubeSong(
        id: videoId,
        title: title,
        author: author,
        thumb: thumb,
        duration: _parseDurationText(durationText),
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------- Radio / "watch next" (unlimited mix) ----------------
  //
  // Ye YT Music ke "Start radio" wala asli feature hai — `next` endpoint,
  // `playlistId: RDAMVM<videoId>` (jo YT Music khud bhejta hai jab user
  // kisi gaane pe "Radio" dabata hai). Pehla call seed videoId se hota hai;
  // uske baad wapas `next` par sirf `continuation` bhejne se agla batch
  // milta hai — isliye ye search/playlist jaisa hi "jab tak YouTube ke
  // paas bacha hai tab tak" chalta reh sakta hai (practically unlimited).
  Future<InnertubePage<InnertubeSong>> radioQueue(
    String seedVideoId, {
    String? continuation,
  }) async {
    Map<String, dynamic>? data;
    if (continuation != null) {
      data = await _post('next', {'continuation': continuation});
    } else {
      data = await _post('next', {
        'videoId': seedVideoId,
        'playlistId': 'RDAMVM$seedVideoId',
        'isAudioOnly': true,
        'enablePersistentPlaylistPanel': true,
        'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      });
    }
    if (data == null) return InnertubePage.empty<InnertubeSong>();
    final rawItems = _findAll(data, 'playlistPanelVideoRenderer');
    final results = <InnertubeSong>[];
    for (final raw in rawItems) {
      final song = _songFromPanelItem(raw);
      if (song != null) results.add(song);
    }
    final nextToken = _findContinuationToken(data);
    return InnertubePage<InnertubeSong>(results, nextToken);
  }

  // ---------------- Lyrics (YT Music "Lyrics" tab) ----------------
  //
  // NEW (v96, lyrics multi-source): yahi public/undocumented InnerTube
  // flow jo ytmusicapi (Python) bhi apne get_lyrics() ke liye use karta
  // hai — koi alag API key ya auth nahi chahiye. Do steps:
  //   1) `next` call se is video ke "watch next" tabs me se "Lyrics" tab
  //      ka browseId nikalo (tab title match ya "MPLYt" prefix se).
  //   2) `browse` call us browseId pe — response ke
  //      `musicDescriptionShelfRenderer.description.runs` hi lyrics text
  //      hota hai, `footer.runs` me source attribution (jaise "Source:
  //      Musixmatch").
  // LIMITATION: ye sirf PLAIN text deta hai. YouTube Music ka apna
  // real-time word-highlight wala synced mode is public endpoint se
  // available nahi hai (ytmusicapi bhi nahi de paata) — isliye is source
  // ko sirf plain-lyrics fallback ki tarah treat karo, synced ke liye
  // nahi.
  Future<String?> _lyricsBrowseId(String videoId) async {
    final data = await _post('next', {'videoId': videoId});
    if (data == null) return null;
    for (final tab in _findAll(data, 'tabRenderer')) {
      if (tab is! Map) continue;
      final title = (tab['title'] as String?)?.toLowerCase() ?? '';
      final browseId =
          tab['endpoint']?['browseEndpoint']?['browseId'] as String?;
      if (browseId == null || browseId.isEmpty) continue;
      if (title.contains('lyrics') || browseId.startsWith('MPLYt')) {
        return browseId;
      }
    }
    return null;
  }

  Future<({String text, String? source})?> getLyrics(String videoId) async {
    try {
      final browseId = await _lyricsBrowseId(videoId);
      if (browseId == null) return null;
      final data = await _post('browse', {'browseId': browseId});
      if (data == null) return null;
      final shelves = _findAll(data, 'musicDescriptionShelfRenderer');
      if (shelves.isEmpty) return null;
      final shelf = shelves.first;
      final descRuns = shelf['description']?['runs'] as List?;
      final text = descRuns?.map((r) => r['text'] as String? ?? '').join().trim();
      if (text == null || text.isEmpty) return null;
      final footerRuns = shelf['footer']?['runs'] as List?;
      final source =
          footerRuns?.map((r) => r['text'] as String? ?? '').join().trim();
      return (
        text: text,
        source: (source != null && source.isNotEmpty) ? source : null,
      );
    } catch (_) {
      return null;
    }
  }
}
