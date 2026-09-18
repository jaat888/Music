// lib/services/chunked_audio_source.dart
//
// PROBLEM (user report, 2026-09-18): "gaana ka URL mil jaata hai, play bhi
// ho jaata hai, par LOAD/BUFFER bahut slow hota hai — jaise ek-ek chunk
// download ho raha ho, ek baar mein zyada chunk nahi aata."
//
// ROOT CAUSE: `player.setUrl(url)` (ab tak) seedha `AudioSource.uri()` use
// karta tha — ExoPlayer isse ek SINGLE continuous HTTP GET connection se
// stream karta hai. YouTube ka CDN (googlevideo.com) is tarah ke "khula"
// requests ko jaanbujhke throttle karta hai — roughly utni hi speed se
// data deta hai jitni playback consume karti hai (anti-bulk-download
// measure), isliye seeking/buffering slow lagti hai chahe network fast ho.
//
// FIX (yt-dlp/NewPipe jaisa hi tarika — `http_chunk_size` option): content
// ko EK continuous request ki jagah BADE FIXED-SIZE HTTP Range chunks
// (10MB, yt-dlp ka bhi default) me sequentially maango. CDN har naye
// discrete range-request ko poori network speed pe serve karta hai —
// throttling sirf "single long-running open connection" pattern par lagti
// hai, chunk-by-chunk explicit range requests par nahi.
//
// BUG FIX (2026-09-18, v2 — user ne pakda): pehla version `http.get()` use
// karta tha, jo poora chunk (10MB tak) memory me buffer karke TABHI
// return karta jab poora chunk download ho chuka ho. Slow network pe
// matlab: gaana tabhi bajna shuru hota jab poore 10MB download ho jaate —
// ulta result (start hi der se hota), bilkul jo user chahta tha uske
// opposite. Do fixes:
//   1) STREAMING response (`http.Client().send()`, StreamedResponse) —
//      bytes network se aate hi seedha player ko milte hain, poore chunk
//      ka wait nahi karna padta. Range chunk sirf "kitna EK BAAR me maango"
//      control karta hai (throttle-bypass ke liye), player ko wait nahi
//      karwata.
//   2) PEHLA chunk CHHOTA (512KB — kuch second ka audio, fast start),
//      USKE BAAD wale chunks bade (10MB, throttle-bypass) — isse start
//      bhi fast, aur baad me bulk-throttle bhi bypass.

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

class ChunkedYoutubeAudioSource extends StreamAudioSource {
  ChunkedYoutubeAudioSource(this.url, {this.headers, super.tag});

  final String url;
  final Map<String, String>? headers;
  final http.Client _client = http.Client();

  // Pehla chunk CHHOTA rakha hai — 512KB, 128kbps audio ka ~32 second —
  // taaki slow network pe bhi playback jaldi shuru ho jaaye (poore 10MB
  // ka wait na karna pade). Baad ke chunks bade (10MB, yt-dlp ka default)
  // — throttling bypass karne ke liye, ab ye blocking nahi hai kyunki
  // streaming response player ko data-as-it-arrives deta hai.
  static const int _firstChunkSize = 512 * 1024;
  static const int _laterChunkSize = 10 * 1024 * 1024;

  int? _totalLength;
  String? _contentType;
  bool _metadataFetched = false;
  int _requestCount = 0;

  Future<void> _ensureMetadata() async {
    if (_metadataFetched) return;
    try {
      final res = await _client.get(
        Uri.parse(url),
        headers: {...?headers, 'Range': 'bytes=0-1'},
      );
      _contentType = res.headers['content-type'] ?? 'audio/mp4';
      final contentRange = res.headers['content-range'];
      if (contentRange != null && contentRange.contains('/')) {
        final totalStr = contentRange.split('/').last.trim();
        _totalLength = int.tryParse(totalStr);
      }
      _totalLength ??= int.tryParse(res.headers['content-length'] ?? '');
    } catch (e) {
      // Metadata na mile to bhi chalte raho — sourceLength null bhi
      // just_audio handle kar leta hai (seek-bar thoda kam accurate ho
      // sakta hai, playback par asar nahi).
      print('ChunkedYoutubeAudioSource: metadata fetch failed: $e');
    } finally {
      _metadataFetched = true;
    }
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    await _ensureMetadata();
    final total = _totalLength;
    final rangeStart = start ?? 0;

    // Pehla hi request (song ka start ya seek ke baad player ka pehla
    // maang) CHHOTA chunk le — fast start. Uske baad bade chunks —
    // throttle-bypass.
    final chunkSize = _requestCount == 0 ? _firstChunkSize : _laterChunkSize;
    _requestCount++;

    // *** ASLI FIX: player agar "jitna mile utna de do" jaisa open-ended
    // request kare (end == null — yahi throttle-prone pattern hai), use
    // fixed chunkSize tak CLAMP kar do. Player is chunk ke khatam hote
    // hi khud-ba-khud agla chunk maang lega — result: kai discrete
    // range-requests, ek lamba throttled connection nahi.
    var rangeEnd = (end != null) ? end - 1 : (rangeStart + chunkSize - 1);
    if (rangeEnd - rangeStart + 1 > chunkSize) {
      rangeEnd = rangeStart + chunkSize - 1;
    }
    if (total != null && rangeEnd > total - 1) {
      rangeEnd = total - 1;
    }

    // STREAMING request — `send()` ka StreamedResponse bytes network se
    // aate hi deta hai, `http.get()` ki tarah poore chunk ka wait nahi
    // karwata. Player isi stream ko seedha consume karta hai, isliye
    // playback pehla byte aate hi (chunk poora hue bina) shuru ho sakta
    // hai.
    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll({...?headers, 'Range': 'bytes=$rangeStart-$rangeEnd'});
    final res = await _client.send(req);

    if (res.statusCode != 200 && res.statusCode != 206) {
      throw Exception(
          'ChunkedYoutubeAudioSource: HTTP ${res.statusCode} for range '
          '$rangeStart-$rangeEnd');
    }

    return StreamAudioResponse(
      sourceLength: total,
      contentLength: res.contentLength ?? (rangeEnd - rangeStart + 1),
      offset: rangeStart,
      stream: res.stream,
      contentType: res.headers['content-type'] ?? _contentType ?? 'audio/mp4',
    );
  }
}
