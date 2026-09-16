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

import 'dart:async';
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
import 'innertube_client.dart';
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

  // BUG FIX (2026-09-16, v20 — REAL root cause of "gaana badalte hi crash",
  // chahe click ho ya gaana khud khatam ho ke agla bajte waqt): background_
  // service.dart ka 300ms debounce + `_playToken` sirf ye control karta hai
  // ki kitni BAAR (aur kab) ek naya resolve SHURU ho — lekin ek baar
  // `_audioViaNewPipe()` (neeche) ke andar `npe.VideoExtractor.getStream()`
  // (NewPipeExtractor ka WebView-based JS solver, `flutter_inappwebview` se
  // wrap kiya gaya) call ho jaaye, wo call khud 5-30 second tak le sakta hai
  // (network + JS challenge solve karne me). Is DAURAAN agar agla song bajna
  // shuru ho (naturally khatam hone ke baad AUTO-NEXT ho ya user ne click
  // kiya — dono se) — debounce ke 300ms nikal chuke hote hain, isliye naya
  // `_resolveAndPlay()` bhi shuru ho jaata hai, aur wo bhi apna khud ka
  // `npe.VideoExtractor.getStream()` call kar deta hai. Ab DO WebView-based
  // native extractions EK SAATH chal rahi hoti hain — chahe user ne bilkul
  // bhi jaldi-jaldi tap na kiya ho, sirf itna ki pehla song abhi bhi resolve
  // ho raha tha jab dusra shuru hua. Yahi asli "1 sec me crash" hai (native
  // WebView OOM/instance-limit, MIUI jaise kam-RAM OEMs pe) — normal ek-ke-
  // baad-ek song transitions me bhi reproduce hota hai, sirf rapid double-
  // tap se nahi. Dart-level try/catch isko pakad nahi sakta kyunki ye native
  // process-level crash hai, koi Dart exception nahi.
  // Fix: `_audioViaNewPipe()` ke poore body ko ek simple chained-Future
  // MUTEX se wrap kiya gaya hai — is se poore app me kabhi bhi EK se zyada
  // NewPipeExtractor WebView call parallel nahi chalegi. Agar koi naya call
  // aata hai jab pehla abhi chal raha hai, wo pehle ke poora khatam (settle)
  // hone ka wait karega, tabhi apna WebView call shuru karega — isse
  // overlapping native instances kabhi bante hi nahi, chahe transitions
  // kitni bhi jaldi-jaldi (ya kitni bhi slow-resolve ke beech) kyun na ho
  // rahe hon.
  Future<void> _newPipeLock = Future.value();

  // ---------------- Search pagination state ("unlimited" scroll) ----------------
  //
  // BUG FIX (2026-09-16, v17): "search me limited hi gaane aate hain,
  // unlimited nahi". Root cause: search() hamesha sirf EK request karta
  // tha — Layer 1 (dart_ytmusic_api's searchSongs()) apne aap me ek single
  // API call hai jiska koi continuation/pagination is wrapper me expose
  // hi nahi hota (jitne results ek baar me aa jaayein, bas utne hi —
  // dobara wahi call karne pe wahi results wapas aayenge, "agla page"
  // jaisa kuch nahi hai). Isi wajah se list hamesha ek fixed chhoti size
  // (~20-30) pe atak jaati thi, chahe max jitna bhi bada rakho.
  // Fix: youtube_explode_dart ka generic search (`yt.search.search()`)
  // asal me paginated hai (`SearchList.nextPage()` se agla page milta
  // hai, jab tak YouTube ke paas aur results hon) — isko "load more"
  // source banaya hai. Pehla page (best-ranked, YT Music curated) ab bhi
  // search() se hi aata hai; jab user list ke end tak scroll kare,
  // loadMoreSearchResults() is naye paginated explode search se agla
  // page laata hai aur jode chala jaata hai — isse scroll karte rehne pe
  // results khatam hone ka koi fixed limit nahi rehta (jab tak YouTube
  // khud ke paas results khatam na kar de).
  // `dynamic` jaanbujhke — youtube_explode_dart ke getVideos() ka exact
  // return type (SearchList<Video> ya kuch alag naam) is codebase me kahin
  // explicitly likha/verify nahi hua (upar wala existing Layer 2 code bhi
  // `final videos = await yt.search.getVideos(query);` type-inference se
  // hi karta hai, kabhi explicit type nahi likhta). Galat type-naam guess
  // karne se pehle bhi compile error aa chuka hai (NOTES.md Batch 16),
  // isliye yahan dynamic + try/catch (jaisa searchArtists/searchPlaylists
  // upar karte hain) — agar package ka `.nextPage()` kisi wajah se na ho
  // ya alag kaam kare, "load more" bas khaali list de dega (list end jaisa
  // dikhega), poori app crash nahi hogi.
  // BUG FIX (2026-09-16, v18): pehle ye youtube_explode_dart ke generic
  // (non-Music) search se "load more" karta tha — isliye page 2 se results
  // "YT Music jaisa" nahi, generic YouTube jaisa dikhne lagte the. Ab apna
  // InnertubeClient (music.youtube.com ka wahi endpoint jo YT Music khud
  // use karta hai) use karta hai, jiska continuation token asli hota hai —
  // isliye pehla page ho ya paanchwa, sabka ranking/source same (YT Music)
  // rehta hai.
  final InnertubeClient _innertube = InnertubeClient.instance;
  String? _moreSearchQuery;
  String? _moreSearchContinuation;
  bool _moreSearchExhausted = false;

  // "next page" chahiye ho to isko call karo — pehli baar isi query ke
  // liye call hone par InnerTube search ka PEHLA page deta hai (jo already
  // search() screen pe dikh chuka hoga, isliye caller apni taraf se
  // duplicate IDs filter kare), uske baad har call agla page deti hai
  // (asli continuation token se). Khaali list wapas aane ka matlab hai
  // YouTube ke paas is query ke liye aur results nahi bache — list yahi
  // khatam maano.
  Future<List<YtResult>> loadMoreSearchResults(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      if (_moreSearchQuery != query) {
        _moreSearchQuery = query;
        _moreSearchContinuation = null;
        _moreSearchExhausted = false;
      }
      if (_moreSearchExhausted) return [];

      final page = await _innertube.searchSongs(
        query,
        continuation: _moreSearchContinuation,
      );
      _moreSearchContinuation = page.continuation;
      if (page.continuation == null) _moreSearchExhausted = true;

      if (page.items.isNotEmpty) {
        return page.items
            .map((s) => YtResult(
                  id: s.id,
                  title: s.title,
                  author: s.author,
                  thumb: s.thumb,
                  duration: s.duration,
                ))
            .toList();
      }

      // InnerTube se kuch na mila (pehli baar hi fail ho gaya ya token
      // expire ho gaya) — purane youtube_explode_dart generic search pe
      // fallback, taaki "load more" bilkul khaali na reh jaaye.
      final yt = await _getYt();
      final videos = await yt.search.getVideos(query);
      _moreSearchExhausted = true; // is fallback path me age continuation nahi
      final results = <YtResult>[];
      for (final dynamic v in videos) {
        try {
          results.add(YtResult(
            id: v.id.value as String,
            title: v.title as String,
            author: v.author as String,
            thumb: v.thumbnails.highResUrl as String,
            duration: (v.duration as Duration?)?.inSeconds ?? 0,
          ));
        } catch (_) {
          continue; // ek item ka shape alag nikla to bas usko skip karo
        }
      }
      return results;
    } catch (e) {
      print('LOAD MORE SEARCH ERROR ($query): $e');
      return [];
    }
  }

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

    // BUG FIX (2026-09-16, v20): "search unlimited nahi, hamesha limited
    // gaane hi aate hain" — asli root cause. `_moreSearchQuery`/
    // `_moreSearchContinuation`/`_moreSearchExhausted` teeno singleton
    // instance fields hain (poore app me ek hi YoutubeService.instance),
    // lekin pehle:
    // (1) Agar `_innertube.searchSongs(query)` (Layer 0) THROW kar jaata
    //     (network flaky, ya YouTube ka internal endpoint kabhi-kabhi
    //     signature change kar de — ye poora Layer 0 hi "assumption/early
    //     stage" hai), to `_moreSearchQuery` already naye query pe set ho
    //     chuka hota tha (exception se PEHLE hi), lekin `_moreSearchContinuation`/
    //     `_moreSearchExhausted` PURANI (kisi bilkul alag pichli query ki)
    //     value pe hi reh jaate the. `loadMoreSearchResults()` ka
    //     `if (_moreSearchQuery != query)` check isliye galti se "match"
    //     maan leta tha (query naam to same hai), aur purani query ka
    //     stale continuation/exhausted-flag naye query pe reuse ho jaata
    //     tha — matlab agar purani query exhausted thi, naya query bhi
    //     turant "no more" maan leta, chahe uske paas khud ke bahut saare
    //     results bache hon.
    // (2) Agar Layer 0 successfully chal jaata lekin `page.items` KHAALI
    //     aata (jabki `page.continuation` non-null ho sakta hai), to
    //     display Layer 1 (dart_ytmusic_api) ya Layer 2 (explode) se hota
    //     tha — lekin continuation/exhausted state Layer 0 ke (khaali)
    //     page se hi set ho chuka hota tha, jo actual displayed results se
    //     match hi nahi karta — "load more" agli baar galat/mismatched
    //     jagah se continue karne ki koshish karta.
    // Fix: (a) har call ki shuruaat me hi in teeno ko unconditionally is
    // naye query ke liye reset kar do (chahe Layer 0 throw kare ya kuch
    // bhi ho, purani query ka state kabhi bhi is naye query pe leak na
    // ho) — default `exhausted: false` taaki agar Layer 0 fail/khaali ho
    // bhi jaaye, `loadMoreSearchResults()` khud apna fallback (explode
    // generic search) try kare bajaye turant "no more" maan lene ke. (b)
    // continuation/exhausted ko sirf TABHI Layer 0 ke response se set
    // karo jab Layer 0 ka page.items khud display ho raha ho (i.e. andar
    // wale `if` ke andar) — taaki pagination state hamesha wahi reflect
    // kare jo user ko screen pe dikh raha hai.
    _moreSearchQuery = query;
    _moreSearchContinuation = null;
    _moreSearchExhausted = false;

    // Layer 0 (NEW, v18): apna InnertubeClient — YT Music ka wahi endpoint
    // jo dart_ytmusic_api internally use karta hai, par yahan pagination
    // token bhi milta hai (loadMoreSearchResults isi query ke liye reset
    // ho jaata hai taaki page-1 yahi rahe, page-2+ usi continuation se aage
    // badhe).
    try {
      onProgress?.call('Searching (innertube)...');
      final page = await _innertube.searchSongs(query);
      if (page.items.isNotEmpty) {
        _moreSearchContinuation = page.continuation;
        _moreSearchExhausted = page.continuation == null;
        onProgress?.call('Innertube: OK, ${page.items.length} results');
        return page.items
            .take(max)
            .map((s) => YtResult(
                  id: s.id,
                  title: s.title,
                  author: s.author,
                  thumb: s.thumb,
                  duration: s.duration,
                ))
            .toList();
      }
      print('Innertube search: 0 usable results, dart_ytmusic_api try kar rahe hain');
    } catch (e) {
      print('Innertube search failed: $e');
    }

    // Layer 1: YT Music native search (music-specific ranking), dart_ytmusic_api ke zariye
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
      final page = await _innertube.searchArtists(query);
      if (page.items.isNotEmpty) {
        return page.items
            .map((a) => YtArtistResult(id: a.id, name: a.name, thumb: a.thumb))
            .toList();
      }
    } catch (e) {
      print('INNERTUBE ARTIST SEARCH FAILED: $e');
    }
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
      final page = await _innertube.searchPlaylists(query);
      if (page.items.isNotEmpty) {
        return page.items
            .map((pl) => YtPlaylistPreview(
                  id: pl.id,
                  title: pl.title,
                  subtitle: pl.subtitle,
                  thumb: pl.thumb,
                ))
            .toList();
      }
    } catch (e) {
      print('INNERTUBE PLAYLIST SEARCH FAILED: $e');
    }
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
  // UPDATED (2026-09-16, v19): pehle ye sirf approximation tha (current
  // song ke artist se search() karke shuffle) — ek hi fixed batch (~15),
  // khatam ho jaata tha, "unlimited" nahi tha. Ab InnertubeClient ka asli
  // radio/"watch next" endpoint use karta hai (`RDAMVM<videoId>` — wahi
  // radio playlist jo YT Music khud "Start radio" pe banata hai), jisme
  // asli continuation token milta hai. Isliye ab practically unlimited ho
  // sakta hai: QueueService radio-mode isko khud call karta hai jab queue
  // khatam hone wali ho (dekho queue_service.dart ka enableRadioMode()).
  String? _radioSeedId;
  String? _radioContinuation;
  bool _radioExhausted = false;

  Song _songFromInnertube(InnertubeSong s) => Song(
        id: s.id,
        title: s.title,
        artist: s.author,
        thumb: s.thumb,
        duration: s.duration,
      );

  Future<List<Song>> getRadioQueue(
    String seedVideoId,
    String seedTitle,
    String seedArtist, {
    int count = 25,
  }) async {
    // Naya radio shuru — purana continuation state reset karo.
    _radioSeedId = seedVideoId;
    _radioContinuation = null;
    _radioExhausted = false;

    try {
      final page = await _innertube.radioQueue(seedVideoId);
      _radioContinuation = page.continuation;
      _radioExhausted = page.continuation == null;
      final filtered = page.items.where((s) => s.id != seedVideoId).toList();
      if (filtered.isNotEmpty) {
        return filtered.take(count).map(_songFromInnertube).toList();
      }
      print('INNERTUBE RADIO: 0 usable results, purana approximation try kar rahe hain');
    } catch (e) {
      print('INNERTUBE RADIO FAILED: $e');
    }

    // Fallback (purana approximation) — ye "unlimited" nahi hai, isliye
    // exhausted mark kar diya taaki loadMoreRadioQueue() seedhe khaali de
    // (QueueService khud-ba-khud refill karna band kar dega, jo already
    // chal raha hai use disturb kiye bina).
    _radioExhausted = true;
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

  // Radio "unlimited" banane wala asli hissa — QueueService (radio-mode
  // on hone par) khud isko call karta hai jab queue khatam hone wali ho.
  // Same seed ka agla batch, asli continuation token se. Khaali list ka
  // matlab: ya continuation khatam ho gaya (YouTube ke paas is radio ke
  // aur gaane nahi bache), ya getRadioQueue() fallback approximation pe
  // gaya tha (jahan continuation hota hi nahi) — dono case me
  // QueueService bas aage refill try karna rok dega.
  Future<List<Song>> loadMoreRadioQueue() async {
    if (_radioSeedId == null || _radioExhausted) return [];
    try {
      final page = await _innertube.radioQueue(
        _radioSeedId!,
        continuation: _radioContinuation,
      );
      _radioContinuation = page.continuation;
      if (page.continuation == null) _radioExhausted = true;
      final filtered =
          page.items.where((s) => s.id != _radioSeedId).toList();
      return filtered.map(_songFromInnertube).toList();
    } catch (e) {
      print('LOAD MORE RADIO ERROR: $e');
      _radioExhausted = true;
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
  //
  // BUG FIX (2026-09-16, v15): dart_ytmusic_api khud apne README me maanta
  // hai ki `getPlaylistVideos()` abhi "not working as expected" hai —
  // "Invalid request" error deta hai, under investigation (package ka
  // apna known bug, humari taraf koi galat usage nahi). Isi wajah se
  // LivePlaylistScreen har playlist ke liye "Kuch nahi mila" dikhata
  // tha. Ab agar ye fail ho ya khaali list de, playlist ke title/
  // subtitle (artist) se normal search() fallback hota hai — jaisa
  // getRadioQueue() pehle se karta hai. Ye exact original playlist
  // tracklist nahi hoga (approximation hai), lekin screen kabhi khaali
  // nahi rahegi jab tak package ka ye bug fix nahi ho jaata.
  Future<List<YtResult>> getYtMusicPlaylistTracks(
    String playlistId, {
    String? fallbackTitle,
    String? fallbackSubtitle,
  }) async {
    // Layer 0 (NEW, v18): apna InnertubeClient — dedicated typed browse
    // call, 3-alag-fallback-library-shape-mismatch wali dikkat yahan nahi
    // aati kyunki dono search() aur ye method same InnertubeSong shape
    // use karte hain.
    try {
      final page = await _innertube.playlistTracks(playlistId);
      if (page.items.isNotEmpty) {
        return page.items
            .map((s) => YtResult(
                  id: s.id,
                  title: s.title,
                  author: s.author,
                  thumb: s.thumb,
                  duration: s.duration,
                ))
            .toList();
      }
      print('INNERTUBE PLAYLIST TRACKS ($playlistId): 0 results, dart_ytmusic_api try kar rahe hain');
    } catch (e) {
      print('INNERTUBE PLAYLIST TRACKS ERROR ($playlistId): $e');
    }

    try {
      final ytmusic = await _getYtMusic();
      final videos = await ytmusic.getPlaylistVideos(playlistId);
      final results = videos
          .where((v) => v.videoId.isNotEmpty)
          .map((v) => YtResult(
                id: v.videoId,
                title: v.name,
                author: v.artist.name,
                thumb: v.thumbnails.isNotEmpty ? v.thumbnails.last.url : '',
                duration: v.duration ?? 0,
              ))
          .toList();
      if (results.isNotEmpty) return results;
      print(
        'YT MUSIC PLAYLIST TRACKS ($playlistId): 0 results (khaali/broken),'
        ' fallback search try kar rahe hain',
      );
    } catch (e) {
      print('YT MUSIC PLAYLIST TRACKS ERROR ($playlistId): $e — fallback search try kar rahe hain');
    }

    // Fallback: playlist ka naam (+ artist/subtitle agar hai) se normal
    // search() karo — getPlaylistVideos() ke fail hone pe bhi user ko
    // "kuch nahi mila" ki jagah related gaane milte hain.
    final query = (fallbackTitle ?? '').trim();
    if (query.isEmpty) return [];
    final fullQuery = (fallbackSubtitle != null && fallbackSubtitle.trim().isNotEmpty)
        ? '$query ${fallbackSubtitle.trim()}'
        : query;
    try {
      return await search(fullQuery, max: 25);
    } catch (e) {
      print('YT MUSIC PLAYLIST TRACKS fallback search bhi FAIL: $e');
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
    // Mutex acquire — dekho `_newPipeLock` comment upar. Apni baari ka wait
    // karo (chahe wo pichhla call kisi bilkul alag song/token ke liye ho).
    final myTurn = Completer<void>();
    final previous = _newPipeLock;
    _newPipeLock = myTurn.future;
    await previous;
    try {
      return await _audioViaNewPipeUnlocked(videoId, onProgress: onProgress);
    } finally {
      myTurn.complete(); // agli waiting call ko aage badhne do
    }
  }

  Future<_AudioStream?> _audioViaNewPipeUnlocked(
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
    // BUG FIX (2026-09-16, Batch 21 — "kuch gaane HAMESHA crash/fail hote
    // hain, kuch HAMESHA chal jaate hain" — user ne khud confirm kiya ki
    // ye per-song CONSISTENT hai, rapid-tap ya "abhi khatam hua" jaisi
    // timing pe depend nahi karta. Iska matlab #49/#51 (overlap) wala
    // mutex fix sahi hai lekin isse ALAG ek doosra root cause bhi hai:
    // ek SINGLE (non-overlapping) NewPipeExtractor call bhi kuch specific
    // videos pe crash kar sakta hai — mutex sirf DO calls ko ek saath
    // chalne se rokta hai, ek akela call agar khud crash kare (kisi
    // specific video ke signature-cipher/JS-challenge shape ki wajah se)
    // to mutex us se bacha hi nahi sakta.
    // Context: `newpipeextractor_dart` (pubspec me pinned) khud bahut NAYA
    // aur chhota package hai (pehla release ~mid-2026, pub.dev par sirf 2
    // likes/~150 downloads total — matlab bahut kam real-world testing) —
    // OuterTune/OpenTune jaisi established Kotlin YT Music apps NewPipe-
    // Extractor ko seedha (native Kotlin/Java) use karti hain, is chhote
    // Flutter-wrapper se nahi, aur unka apna alag actively-maintained
    // innertube module hai — isliye unke paas ye specific per-video native
    // crash class kam dikhti hai. Yahan wo option nahi hai (Flutter app
    // hai), lekin jitna kam is package pe depend karein utna crash-surface
    // kam.
    // Fix: order badal diya — pehle `_audioViaExplode()` (youtube_
    // explode_dart, pure Dart, koi native WebView nahi, isliye kabhi
    // process-level crash nahi karega) try karo. Sirf agar wo fail ho
    // (null return — YouTube ke bot-detection se URL na mile, jaisa header
    // comment me already documented hai) tab NewPipeExtractor (WebView-
    // based, behtar bypass-rate lekin crash-risk wala) fallback ki tarah
    // try karo. Isse jitne bhi gaane explode se seedha resolve ho jaate
    // hain, unke liye crash-prone path kabhi chhua hi nahi jaata; jo
    // explode pe fail hote hain (asli "bypass zaroori hai" cases), unhi ke
    // liye NewPipeExtractor ka risk accept kiya jaata hai.
    // NOTE: is se stream-fetch SUCCESS RATE thoda kam ho sakta hai kuch
    // videos ke liye (explode occasionally NewPipe se kam reliable hai,
    // dekho file-header comment) — trade-off jaanbujhke hai (crash >>
    // ek retry/error message, jaisa mutex fix me bhi "safety > speed"
    // tradeoff liya gaya tha).
    final viaExplode =
        await _audioViaExplode(resolvedId, onProgress: onProgress);
    if (viaExplode != null) return viaExplode;

    final viaNewPipe = await _audioViaNewPipe(resolvedId, onProgress: onProgress);
    if (viaNewPipe != null) return viaNewPipe;

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
