// lib/services/potoken_service.dart
//
// NEW (2026-09-17) — "REAL FIX" for PoToken-restricted stream drops.
//
// ===================== PROBLEM (dekho sursathi_app_log.txt) =====================
// Log me exact pattern ye tha: YT explode/NewPipe se stream URL milta hai,
// `just_audio` ka setUrl() bhi PASS ho jaata hai (matlab URL khud valid/
// reachable tha), lekin kuch second ke andar hi ExoPlayer "Source error"
// de deta — poora "URL mila -> chala -> beech me drop" cycle. Ye bilkul
// wahi signature hai jo YouTube ka CDN "unverified client" streams ke
// saath karta hai jab request me PoToken (Google BotGuard/Proof-of-Origin
// token) attach nahi hota.
//
// ===================== FIX (Option 1 — real BotGuard solver) =====================
// Hidden WebView me `bgutils-js` (LuanRT/BgUtils — public, open-source,
// documented BotGuard/PoToken flow: Challenge.create -> BotGuardClient
// -> snapshot -> GenerateIT -> WebPoMinter -> mintAsWebSafeString) chala
// ke ek session-bound PO Token mint karte hain, aur usse youtube_service.dart
// me har resolved stream URL pe `&pot=<token>` attach karte hain.
//
// ===================== ATTEMPT #1 FAILED (2026-09-17) =====================
// Pehla version seedha `https://www.youtube.com` WebView me load karta
// tha — asli YouTube page khud "Trusted Types" CSP enforce karta hai, jo
// SIRF `<script>.src` assignment nahi, `eval`/`new Function()` (koi bhi
// string-to-JS execution) bhi poori tarah block karta hai. Real-device log:
// "Evaluating a string as JavaScript violates this document's Trusted Type
// assignment requirements." Matlab: asli youtube.com page ke andar humari
// khud ki arbitrary JS (bgutils-js load karna, ya use run karna) chalti hi
// nahi — chahe `<script src>` se ho ya `fetch()+Function()` se, dono
// blocked hain, kyunki restriction poore document pe hai, sirf ek DOM sink
// pe nahi.
//
// ===================== ATTEMPT #2 (yahi file, current) =====================
// Fix: WebView ko asli youtube.com URL load karne ki jagah ek apna
// KHAALI/NEUTRAL HTML page (`loadHtmlString`) diya jaata hai — is page ki
// apni koi CSP hi nahi hai (hum khud HTML bana rahe hain, koi CSP header/
// meta tag nahi daal rahe), isliye eval/Function/script-tag sab normally
// chalते hain. Lekin `baseUrl: 'https://www.youtube.com'` pass karte hain
// (Android WebView ka `loadDataWithBaseURL` — webview_flutter isko
// `loadHtmlString(html, baseUrl: ...)` se expose karta hai) — isse page ka
// ORIGIN (fetch()/CORS ke liye) youtube.com jaisa treat hota hai, bina
// asli youtube.com ka HTTP response (aur uske saath aane wale CSP headers)
// actually load kiye. Matlab: CORS-safe (Google APIs ko same-origin
// dikhega) + CSP-free (apni JS chala sakte hain) — dono fayde.
//
// Is wajah se ab humein `ytcfg` (jo sirf asli page pe available hota) se
// visitorData nikalne wala purana tarika bhi hata diya — uski jagah khud
// ek chhota innertube `player` API call (`fetch()` se, isi WebView ke
// andar, isi liye same-origin) karke response ke `responseContext.
// visitorData` se visitorData nikalte hain (koi bhi innertube endpoint ka
// response ye field deta hai, chahe request khud kisi aur reason se fail
// ho jaaye — ye common/documented tarika hai visitorData bootstrap karne
// ka).
//
// *** IMPORTANT — HONESTY NOTE (isko README/NOTES.md me bhi rakhna) ***
// - Ye is environment (sandboxed container, no network/Android SDK) me
//   COMPILE ya LIVE-TEST NAHI ho saka hai. `loadHtmlString(..., baseUrl:)`
//   se same-origin fetch() milna Android WebView ki well-known technique
//   hai, lekin device/WebView-version ke hisaab se behavior thoda alag ho
//   sakta hai — agla real-device log hi confirm karega.
// - Fail-soft hai: mint kisi bhi step pe fail ho (debug/app log me
//   "PoToken mint FAILED: ..." dikhega) to bas `pot` param skip ho jaata
//   hai, app purane (bina-pot) behavior pe chalti rehti hai — koi crash
//   nahi.
// - `requestKey` public constant hai (BgUtils/yt-dlp docs), koi secret
//   nahi. YouTube kabhi rotate kare to fail-soft hi fail hoga.
// - NewPipeExtractor (native Kotlin layer) is fix se cover NAHI hota — sirf
//   youtube_explode_dart layer ke resolved URL pe poToken lagta hai.

import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

class PoTokenService {
  PoTokenService._internal();
  static final PoTokenService instance = PoTokenService._internal();

  // BgUtils/yt-dlp docs me publish hua public "web" requestKey — koi secret
  // nahi, isi tarah har open-source PoToken implementation me hardcoded
  // milta hai.
  static const String _requestKey = 'O43z0dpjhgX20SCx4KAo';

  // bgutils-js UMD bundle — jsdelivr CDN, pinned version.
  static const String _bgutilsCdnUrl =
      'https://cdn.jsdelivr.net/npm/bgutils-js@2.6.0/dist/index.min.js';

  // Public YouTube WEB client InnerTube API key — koi secret nahi, YouTube
  // ke apne web player bundle me hardcoded hota hai, dozens of open-source
  // projects (yt-dlp waghera) me bhi yahi milega. Sirf visitorData
  // bootstrap karne ke liye ek minimal `player` call ke liye chahiye.
  static const String _webApiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

  WebViewController? _controller;
  bool _pageReady = false;

  String? _cachedToken;
  DateTime? _cachedAt;
  static const Duration _cacheTtl = Duration(hours: 4);

  Completer<Map<String, dynamic>>? _pendingMint;

  WebViewController get controller {
    _controller ??= _buildController();
    return _controller!;
  }

  WebViewController _buildController() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'PoTokenBridge',
        onMessageReceived: (JavaScriptMessage msg) {
          try {
            final data = jsonDecode(msg.message) as Map<String, dynamic>;
            _pendingMint?.complete(data);
          } catch (e) {
            _pendingMint?.complete({'ok': false, 'error': 'bridge parse: $e'});
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _pageReady = true,
        ),
      )
      // ATTEMPT #2 fix: asli youtube.com load NAHI karte (uska CSP saari
      // arbitrary JS block kar deta hai) — apna khaali HTML, youtube.com
      // ko sirf ORIGIN (baseUrl) ki tarah pass karte hain taaki fetch()
      // calls CORS-safe rahein.
      ..loadHtmlString(
        '<!DOCTYPE html><html><head></head><body></body></html>',
        baseUrl: 'https://www.youtube.com',
      );
    return c;
  }

  Future<String?> getSessionPoToken({
    void Function(String status)? onProgress,
  }) async {
    final cached = _cachedToken;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return cached;
    }

    try {
      onProgress?.call('PoToken: minting (BotGuard)...');
      final result = await _mintViaWebView().timeout(
        const Duration(seconds: 20),
        onTimeout: () => {'ok': false, 'error': 'mint timeout (20s)'},
      );
      if (result['ok'] != true) {
        onProgress?.call('PoToken: FAILED (${result['error']})');
        print('PoToken mint FAILED: ${result['error']}');
        return null;
      }
      final token = result['token'] as String?;
      if (token == null || token.isEmpty) {
        onProgress?.call('PoToken: FAILED (empty token)');
        return null;
      }
      _cachedToken = token;
      _cachedAt = DateTime.now();
      onProgress?.call('PoToken: OK (minted, cached)');
      print('PoToken mint OK — cached for ${_cacheTtl.inHours}h');
      return token;
    } catch (e) {
      onProgress?.call('PoToken: FAILED (unexpected) $e');
      print('PoToken mint FAILED (unexpected): $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> _mintViaWebView() async {
    if (_pendingMint != null) {
      return _pendingMint!.future;
    }
    final completer = Completer<Map<String, dynamic>>();
    _pendingMint = completer;
    try {
      final c = controller;
      var waited = 0;
      while (!_pageReady && waited < 8000) {
        await Future.delayed(const Duration(milliseconds: 200));
        waited += 200;
      }
      if (!_pageReady) {
        completer.complete({'ok': false, 'error': 'WebView page not ready'});
        return await completer.future;
      }

      await c.runJavaScript(_bootstrapJs);
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete({'ok': false, 'error': 'runJavaScript: $e'});
      }
    }
    final result = await completer.future;
    _pendingMint = null;
    return result;
  }

  static final String _bootstrapJs = r'''
(async function () {
  function reply(obj) {
    try { PoTokenBridge.postMessage(JSON.stringify(obj)); } catch (e) {}
  }
  try {
    // Neutral page hai (koi CSP nahi) — fetch+Function dono safe hain yahan
    // (dekho file ke top ka "ATTEMPT #2" comment).
    if (!window.__bgUtilsLoaded) {
      const bgutilsSrc = await (await window.fetch("BGUTILS_CDN_URL")).text();
      // eslint-disable-next-line no-new-func
      new Function(bgutilsSrc)();
      window.__bgUtilsLoaded = true;
    }
    if (!window.BgUtils && !window.BG) {
      reply({ok: false, error: 'bgutils-js global not found after load'});
      return;
    }
    const BG = window.BG || window.BgUtils;

    // visitorData: asli page nahi hai isliye `ytcfg` nahi milega — khud
    // ek chhota innertube `player` call se bootstrap karte hain (fetch()
    // baseUrl trick ki wajah se youtube.com-origin maani jaati hai,
    // CORS-safe).
    let visitorData = null;
    try {
      const vdResp = await window.fetch(
        "https://www.youtube.com/youtubei/v1/player?key=WEB_API_KEY&prettyPrint=false",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            videoId: "dQw4w9WgXcQ",
            context: {
              client: {
                clientName: "WEB",
                clientVersion: "2.20240101.00.00",
                hl: "en",
                gl: "US",
              },
            },
          }),
        }
      );
      const vdJson = await vdResp.json();
      visitorData = vdJson && vdJson.responseContext &&
        vdJson.responseContext.visitorData || null;
    } catch (e) {
      reply({ok: false, error: 'visitorData bootstrap fetch failed: ' + (e && e.message || e)});
      return;
    }
    if (!visitorData) {
      reply({ok: false, error: 'visitorData not found in player response'});
      return;
    }

    const bgConfig = {
      fetch: (input, init) => window.fetch(input, init),
      globalObj: window,
      identifier: visitorData,
      requestKey: "REQUEST_KEY",
    };

    const challenge = await BG.Challenge.create(bgConfig);
    if (!challenge) { reply({ok:false, error:'Challenge.create returned null'}); return; }

    const interpreterJs = challenge.interpreterJavascript &&
      challenge.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
    if (interpreterJs) {
      // eslint-disable-next-line no-new-func
      new Function(interpreterJs)();
    } else {
      reply({ok:false, error:'no interpreterJavascript in challenge'});
      return;
    }

    const botguardClient = await BG.BotGuardClient.create({
      program: challenge.program,
      globalName: challenge.globalName,
      globalObj: window,
    });

    const webPoSignalOutput = [];
    const botguardResponse = await botguardClient.snapshot({ webPoSignalOutput });

    const integrityTokenResponse = await BG.GenerateIT.fetch(
      "REQUEST_KEY", botguardResponse, bgConfig);

    const minter = await BG.WebPoMinter.create(
      { integrityTokenResponse }, webPoSignalOutput);

    const poToken = await minter.mintAsWebSafeString(visitorData);
    reply({ok: true, token: poToken, visitorData: visitorData});
  } catch (e) {
    reply({ok: false, error: String(e && e.message || e)});
  }
})();
'''
      .replaceAll('BGUTILS_CDN_URL', _bgutilsCdnUrl)
      .replaceAll('REQUEST_KEY', _requestKey)
      .replaceAll('WEB_API_KEY', _webApiKey);
}
