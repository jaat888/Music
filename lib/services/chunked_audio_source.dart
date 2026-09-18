// lib/services/chunked_audio_source.dart
//
// PROBLEM (user report, 2026-09-18): "gaana ka URL mil jaata hai, play bhi
// ho jaata hai, par LOAD/BUFFER bahut slow hota hai — jaise ek-ek chunk
// download ho raha ho, ek baar mein zyada chunk nahi aata."
//
// ROOT CAUSE: `player.setUrl(url)` seedha `AudioSource.uri()` use karta hai
// — ExoPlayer isse ek SINGLE continuous HTTP GET connection se stream karta
// hai. YouTube ka CDN (googlevideo.com) is tarah ke "khula" requests ko
// jaanbujhke throttle karta hai (roughly realtime playback speed tak,
// anti-bulk-download measure), isliye seeking/buffering slow lagti hai
// chahe network fast ho.
//
// FIX (yt-dlp/NewPipe jaisa hi tarika — `http_chunk_size` option): content
// ko EK continuous request ki jagah BADE FIXED-SIZE HTTP Range chunks
// (10MB, yt-dlp ka bhi default) me sequentially maango. CDN har naye
// discrete range-request ko poori network speed pe serve karta hai.
//
// ===================== ATTEMPT #1 FAILED (v60, real-device) =====================
// Pehla version `http.get()` (poora chunk buffer karke tabhi return) —
// slow-network pe start hi der se hota tha. Fix kiya: streaming response
// (`http.Client().send()`) + chhota pehla chunk (512KB) — theek se socha
// gaya tha, LEKIN isi version me ek chhupa hua bug tha jiski wajah se
// SAARE gaane turant "Source error" dene lage (v60 se bhi bura — pehle
// sirf slow tha, ab bilkul chalta hi nahi tha).
//
// ROOT CAUSE (is baar dhyan se pin kiya, guess nahi): `request()` har call
// pe `contentLength: res.contentLength ?? (rangeEnd - rangeStart + 1)`
// bhejta tha — matlab "humne jitna MAANGA utna hi assume kar liya" jab bhi
// server ka `Content-Length` header khaali ho. Do practical wajah se ye
// FAIL hota hai:
//   1. `http.Client().send()` (streaming) ke response me googlevideo kabhi
//      `Transfer-Encoding: chunked` bhi bhejta hai — tab `Content-Length`
//      header hi NAHI hota, `res.contentLength` null aata hai.
//   2. Google ka CDN humari maangi hui range (jaise 10MB) hamesha
//      POORI honor nahi karta — kabhi usse KAM bhi bhej deta hai (status
//      206 rehta hai, bas actual bytes kam hote hain).
// Dono cases me hum just_audio ko GALAT (assumed, real se bada) length
// bata dete the — ExoPlayer utne bytes ka wait karta reh jaata, stream
// jaldi khatam ho jaata → data-length mismatch → turant "Source error",
// HAR gaane pe (isliye "saare gaane turant fail" — systematic, random
// nahi).
//
// FIX (yahi file, current — v2): assumed length par kabhi bhi rely nahi
// karte. Har response ka apna `Content-Range: bytes START-END/TOTAL`
// header parse karke SERVER SE ASLI mila hua byte-range nikalte hain, aur
// USI se `contentLength` banate hain. Ye header hi ek EK ground-truth hai
// ki is particular response me kitne bytes aa rahe hain — na hamari maang,
// na koi assumption. `Content-Range` na mile (rare) to hi `res.contentLength`
// pe fallback, aur wo bhi na ho tabhi jaake purana "jo maanga wahi hai"
// assumption — ab sirf last-resort, primary source nahi.
//
// *** IMPORTANT — ABHI BHI REAL-DEVICE PE UNVERIFIED HAI ***
// Isi wajah se background_service.dart me ise SIRF pehle/fresh-play
// attempt pe try kiya jaata hai — koi bhi stream-drop retry hamesha
// wapas PLAIN `setUrl()` (proven-reliable) pe fall back karta hai, kabhi
// dobara chunked try nahi karta. Matlab: best case speed better, worst
// case bhi utna hi reliable jitna pehle tha (bas ek chhota retry zyada).
// ===================== ATTEMPT #3 (yahi file, current) — extra round-trip
// hataya =====================
// User ne pointed out: URL already `youtube_service.dart` ke
// `_verifyPlayable()` se ek baar verify ho chuka hota hai (resolve ke
// dauraan) — uske baad ye file khud apna ALAG "metadata" pre-flight
// (`Range: bytes=0-1`) bhi karti thi sirf total-length/content-type
// jaanne ke liye, phir turant asli pehla chunk maangti thi. Matlab har
// song ke liye 2 network round-trips (1 verify + 1 metadata pre-flight)
// asli chunk se PEHLE — jo playback start hone mein hi extra latency
// jodta tha, wahi jo speed-fix khatam karna chahta tha.
// Fix: alag pre-flight hataya. Total-length/content-type ab PEHLE REAL
// CHUNK ki response se hi nikalte hain (jo `Content-Range: .../TOTAL`
// header waise bhi bhejta hai) — koi extra request nahi, sirf jo
// already ho rahi thi usi se info nikaal lete hain.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

class ChunkedYoutubeAudioSource extends StreamAudioSource {
  ChunkedYoutubeAudioSource(this.url, {this.headers, super.tag});

  final String url;
  final Map<String, String>? headers;
  final http.Client _client = http.Client();

  // Pehla chunk CHHOTA rakha hai — 512KB, 128kbps audio ka ~32 second —
  // taaki slow network pe bhi playback jaldi shuru ho jaaye. Baad ke
  // chunks bade (10MB, yt-dlp ka default) — throttling bypass karne ke
  // liye; streaming response ki wajah se ye blocking nahi hai.
  static const int _firstChunkSize = 512 * 1024;
  static const int _laterChunkSize = 10 * 1024 * 1024;

  int? _totalLength;
  String? _contentType;
  int _requestCount = 0;

  // "bytes START-END/TOTAL" se sirf TOTAL nikaalo.
  int? _parseTotalFromContentRange(String? contentRange) {
    if (contentRange == null || !contentRange.contains('/')) return null;
    final totalStr = contentRange.split('/').last.trim();
    if (totalStr == '*') return null; // server ko total pata hi nahi
    return int.tryParse(totalStr);
  }

  // "bytes START-END/TOTAL" se ACTUAL served start/end nikaalo — ye woh
  // ASLI FIX wala hissa hai: humari maang nahi, server ne kya bheja wahi.
  ({int start, int end})? _parseServedRange(String? contentRange) {
    if (contentRange == null) return null;
    final bytesPart = contentRange.replaceFirst('bytes ', '').split('/').first;
    final parts = bytesPart.split('-');
    if (parts.length != 2) return null;
    final s = int.tryParse(parts[0].trim());
    final e = int.tryParse(parts[1].trim());
    if (s == null || e == null) return null;
    return (start: s, end: e);
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // NOTE: pehle yahan ek alag `_ensureMetadata()` pre-flight call hota
    // tha (dekho upar wala "ATTEMPT #3" comment) — hataya gaya, ab total
    // length/content-type isi asli chunk-request ki response se nikalte
    // hain (neeche).
    final total = _totalLength;
    final rangeStart = start ?? 0;

    // Pehli hi request (song ka start ya seek ke baad player ka pehla
    // maang) CHHOTA chunk le — fast start. Uske baad bade chunks —
    // throttle-bypass.
    final chunkSize = _requestCount == 0 ? _firstChunkSize : _laterChunkSize;
    _requestCount++;

    // Player agar "jitna mile utna de do" jaisa open-ended request kare
    // (end == null — yahi throttle-prone pattern hai), use fixed
    // chunkSize tak CLAMP kar do. Player is chunk ke khatam hote hi
    // khud-ba-khud agla chunk maang lega.
    var rangeEnd = (end != null) ? end - 1 : (rangeStart + chunkSize - 1);
    if (rangeEnd - rangeStart + 1 > chunkSize) {
      rangeEnd = rangeStart + chunkSize - 1;
    }
    if (total != null && rangeEnd > total - 1) {
      rangeEnd = total - 1;
    }

    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll({...?headers, 'Range': 'bytes=$rangeStart-$rangeEnd'});
    final res = await _client.send(req);

    if (res.statusCode != 200 && res.statusCode != 206) {
      throw Exception(
          'ChunkedYoutubeAudioSource: HTTP ${res.statusCode} for range '
          '$rangeStart-$rangeEnd');
    }

    // Isi response se metadata bhi nikaal lo (koi extra request nahi) —
    // sirf pehli baar (baad ki requests me total/contentType already
    // pata hai).
    final contentRangeHeader = res.headers['content-range'];
    _totalLength ??= _parseTotalFromContentRange(contentRangeHeader) ??
        int.tryParse(res.headers['content-length'] ?? '');
    _contentType ??= res.headers['content-type'];

    // *** ASLI FIX (v2): server jo ACTUALLY bhej raha hai usi se
    // contentLength nikaalo — humne kitna maanga tha usse NAHI. Priority:
    //   1. Content-Range header ka served start-end (sabse reliable —
    //      ground truth, chunked-transfer-encoding me bhi hota hai)
    //   2. Content-Length header (fallback)
    //   3. Humari maangi hui range (LAST resort — sirf tab jab dono upar
    //      wale headers hi missing hon, jo rare hai)
    final servedRange = _parseServedRange(contentRangeHeader);
    final int servedLength;
    if (servedRange != null) {
      servedLength = servedRange.end - servedRange.start + 1;
    } else if (res.contentLength != null) {
      servedLength = res.contentLength!;
    } else {
      servedLength = rangeEnd - rangeStart + 1;
    }

    return StreamAudioResponse(
      sourceLength: total,
      contentLength: servedLength,
      offset: rangeStart,
      stream: res.stream,
      contentType: res.headers['content-type'] ?? _contentType ?? 'audio/mp4',
    );
  }
}

