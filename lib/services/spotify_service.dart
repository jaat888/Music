// lib/services/spotify_service.dart
//
// Spotify se SIRF public playlist ka metadata (track title + artist) nikalne
// ke liye — koi audio, koi user login/OAuth nahi. "Client Credentials" flow
// use hota hai (Spotify ka official, app-level auth — user consent screen
// nahi aata, sirf app khud apne Client ID/Secret se ek access token leta
// hai). Ye access token sirf public catalog data tak access deta hai.
//
// Client ID/Secret build-time pe `--dart-define-from-file=env.json` se
// inject hote hain (dekho README/CHAT instructions) — source code ya git
// history me kabhi nahi likhe jaate. env.json khud .gitignore me hai.
import 'dart:convert';
import 'package:http/http.dart' as http;

// Lightweight track metadata — audio nahi, sirf title+artist (YouTube pe
// match karne ke liye kaafi hai).
class SpotifyTrackMeta {
  final String title;
  final String artist;
  SpotifyTrackMeta({required this.title, required this.artist});
}

class SpotifyPlaylistMeta {
  final String name;
  final List<SpotifyTrackMeta> tracks;
  SpotifyPlaylistMeta({required this.name, required this.tracks});
}

class SpotifyService {
  SpotifyService._internal();
  static final SpotifyService instance = SpotifyService._internal();

  static const String _clientId =
      String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const String _clientSecret =
      String.fromEnvironment('SPOTIFY_CLIENT_SECRET');

  bool get isConfigured => _clientId.isNotEmpty && _clientSecret.isNotEmpty;

  String? _accessToken;
  DateTime? _tokenExpiry;

  Future<String> _getToken() async {
    // Cached token abhi bhi valid hai (60s safety margin) to reuse karo —
    // token ~1 ghante ke liye valid hota hai, har request pe naya lena
    // fizool hai.
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(seconds: 60)))) {
      return _accessToken!;
    }

    if (!isConfigured) {
      throw StateError(
        'Spotify Client ID/Secret set nahi hain. Build karte waqt '
        '--dart-define-from-file=env.json pass karo.',
      );
    }

    final basicAuth = base64Encode(utf8.encode('$_clientId:$_clientSecret'));
    final response = await http.post(
      Uri.parse('https://accounts.spotify.com/api/token'),
      headers: {
        'Authorization': 'Basic $basicAuth',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'grant_type': 'client_credentials'},
    );

    if (response.statusCode != 200) {
      throw Exception('Spotify auth fail (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = data['access_token'] as String;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    return _accessToken!;
  }

  // "https://open.spotify.com/playlist/37i9dQZF1..." ya bare ID dono chalte
  // hain.
  static String? extractPlaylistId(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.pathSegments.contains('playlist')) {
      final idx = uri.pathSegments.indexOf('playlist');
      if (idx + 1 < uri.pathSegments.length) {
        return uri.pathSegments[idx + 1].split('?').first;
      }
    }
    // Bare ID (base62, koi slash/space nahi) — playlist link nahi, seedha
    // ID paste kiya ho sakta hai.
    if (RegExp(r'^[A-Za-z0-9]{15,30}$').hasMatch(trimmed)) return trimmed;
    return null;
  }

  // Poori playlist ke tracks — pagination handle karta hai (Spotify ek
  // request me max 100 hi deta hai).
  Future<SpotifyPlaylistMeta> getPlaylistTracks(String playlistId) async {
    final token = await _getToken();
    final headers = {'Authorization': 'Bearer $token'};

    // Playlist ka naam
    final nameRes = await http.get(
      Uri.parse(
        'https://api.spotify.com/v1/playlists/$playlistId?fields=name',
      ),
      headers: headers,
    );
    if (nameRes.statusCode == 404) {
      throw Exception('Playlist nahi mili — private ho sakti hai ya link galat hai.');
    }
    if (nameRes.statusCode != 200) {
      throw Exception('Spotify error (${nameRes.statusCode}): ${nameRes.body}');
    }
    final name = (jsonDecode(nameRes.body) as Map<String, dynamic>)['name']
            as String? ??
        'Imported Playlist';

    final tracks = <SpotifyTrackMeta>[];
    String? next =
        'https://api.spotify.com/v1/playlists/$playlistId/tracks?limit=100'
        '&fields=items(track(name,artists(name))),next';

    while (next != null) {
      final res = await http.get(Uri.parse(next), headers: headers);
      if (res.statusCode != 200) {
        throw Exception('Spotify error (${res.statusCode}): ${res.body}');
      }
      final page = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (page['items'] as List?) ?? [];
      for (final item in items) {
        final track = item['track'] as Map<String, dynamic>?;
        if (track == null) continue; // deleted/local track — skip
        final title = track['name'] as String?;
        final artists = (track['artists'] as List?)
                ?.map((a) => a['name'] as String? ?? '')
                .where((a) => a.isNotEmpty)
                .join(', ') ??
            '';
        if (title == null || title.isEmpty) continue;
        tracks.add(SpotifyTrackMeta(title: title, artist: artists));
      }
      next = page['next'] as String?;
    }

    return SpotifyPlaylistMeta(name: name, tracks: tracks);
  }
}
