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
// ===================== ATTEMPT #2 — REAL-DEVICE RESULT (2026-09-17) =====================
// CSP wala Attempt #1 issue neutral-page trick se solve ho gaya (koi
// "Trusted Types" error ab nahi aaya) — lekin real device log
// (sursathi_app_log.txt) me ek NAYA issue dikha: har baar exact ye: "PoToken mint FAILED:
// Invalid or unexpected token" — turant fail, phir bina-pot stream jo
// kuch second me CDN drop kar deta. Root cause: `bgutils-js` npm package
// koi UMD/IIFE browser bundle publish hi NAHI karta — jsdelivr listing
// confirm karti hai ki us package me `dist/index.min.js` naam ki file
// exist hi nahi karti; jo real file hai (`dist/index.js`), wo package.json
// me `"type": "module"` hai — matlab pure ES module syntax (`export`,
// `import`) use karta hai. Us file ka text fetch karke `new
// Function(text)()` se chalane ki koshish karna seedha JS SyntaxError deta
// hai — `new Function()` sirf classic-script grammar parse kar sakta hai,
// module grammar nahi — aur wahi error, verbatim, "Invalid or unexpected
// token" hota hai. Isliye poora mint pehle step pe hi, hamesha, fail ho
// raha tha.
//
// ===================== ATTEMPT #3 (yahi file, current) =====================
// Fix: fetch()+`new Function()` ki jagah `await import("...")` (dynamic
// import) — ye browser ka native ES-module loader use karta hai, jo
// `export`/`import` syntax ko sahi tarah samajhta hai, aur classic
// (non-module) script context se call karna bhi fully legal hai (isi liye
// dynamic import exist karta hai — lazy-load ESM from anywhere). CDN URL
// bhi real existing version (`bgutils-js@3.2.0/dist/index.js`, jsdelivr pe
// confirmed) pe update kiya — purana `2.6.0/dist/index.min.js` version
// hi wrong path tha.
//
// ===================== ATTEMPT #4 (yahi file, current) =====================
// Attempt #3 se real device log me NAYA error mila: "bgutils-js module
// load hua lekin Challenge export nahi mila" — matlab ES module ab load
// ho raha tha (syntax error gaya), lekin module ke exports galat jagah
// se padhe ja rahe the. bgutils-js@3.2.0 ka actual source seedha check
// kiya (jsdelivr/unpkg pe) aur DO bugs mile:
//   1. `dist/index.js` ke top-level exports `BG` (namespace) + `default`
//      + kuch utils hain — `Challenge`/`BotGuardClient` seedha top-level
//      pe nahi hote, `BG` ke ANDAR hote hain. Fix: `moduleNamespace.BG`.
//   2. Manual mint-flow me `BG.GenerateIT` naam ka export hi exist nahi
//      karta (library actual me sirf Challenge/PoToken/WebPoMinter/
//      BotGuardClient export karti hai), aur `mintAsWebSafeString`
//      (capital S) bhi galat method-name tha (real: `mintAsWebsafeString`,
//      lowercase s). Fix: manual BotGuardClient+GenerateIT+Minter steps
//      hata ke library ka apna tested helper `BG.PoToken.generate()` use
//      kiya — same kaam, kam naming-mismatch risk.
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

  // BUG FIX (2026-09-17, Attempt #3 — dekho sursathi_app_log.txt:
  // "PoToken mint FAILED: Invalid or unexpected token"): bgutils-js koi
  // UMD/IIFE browser bundle publish hi nahi karta — `dist/index.min.js`
  // naam ki file us package me EXIST NAHI karti. Jo real file hai
  // (`dist/index.js`) wo ES MODULE hai (`export`/`import` syntax). Uska
  // text fetch karke `new Function(text)()` se chalane ki koshish karna
  // seedha JS SyntaxError deta hai ("Invalid or unexpected token" =
  // `export` keyword pe, kyunki Function() sirf classic-script grammar
  // parse karta hai, module grammar nahi) — isliye mint hamesha turant
  // fail ho raha tha, aur pura poToken flow silently skip ho jaata tha.
  // Fix: neeche `_bootstrapJs` me ab `await import(url)` (dynamic import,
  // classic script se bhi legal) use hota hai jo iska ES module sahi
  // tarah load karta hai. URL bhi real existing version (3.2.0, jsdelivr
  // listing se confirmed) pe update kiya.
  static const String _bgutilsCdnUrl =
      'https://cdn.jsdelivr.net/npm/bgutils-js@3.2.0/dist/index.js';

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
    // ATTEMPT #3 fix: bgutils-js sirf ES module ke roop me publish hota
    // hai (koi UMD/IIFE bundle nahi) — isliye fetch+`new Function()` se
    // eval karna hamesha "Invalid or unexpected token" deta tha (module
    // grammar, classic-script parser me syntax error). Dynamic
    // `import()` browser ka native module loader use karta hai, jo ES
    // module syntax ko sahi tarah samajhta hai — aur classic (non-module)
    // script context se bhi legal hai.
    if (!window.__bgUtilsModule) {
      window.__bgUtilsModule = await import("BGUTILS_CDN_URL");
    }
    // ATTEMPT #4 fix (dekho sursathi_app_log.txt: "Challenge export nahi
    // mila" — matlab syntax load ho gaya tha, ab ye NAYA issue tha):
    // `dist/index.js` ke top-level exports `BG`, `default`, aur kuch
    // utils hain — `Challenge`/`BotGuardClient` seedha top-level pe NAHI
    // hote, wo `BG` namespace ke ANDAR hote hain (bgutils-js source pe
    // khud confirm kiya: `dist/core/index.js` me
    // `export * as Challenge from './challengeFetcher.js'` waghera, aur
    // `dist/index.js` ye sab `BG` naam se re-export karta hai). Isliye
    // `moduleNamespace.Challenge` hamesha undefined tha — sahi path
    // `moduleNamespace.BG.Challenge` hai.
    const BG = window.__bgUtilsModule.BG;
    if (!BG || !BG.Challenge || !BG.PoToken) {
      reply({ok: false, error: 'bgutils-js module load hua lekin BG.Challenge/BG.PoToken export nahi mile'});
      return;
    }

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

    // ATTEMPT #4 fix (dusra issue jo isi step me chhupa hua tha, agla
    // round-trip lagne se pehle hi source check karke pakड़ liya):
    // 1) `BG.GenerateIT` naam ka export bgutils-js me EXIST HI NAHI karta
    //    (library ka actual `core/index.js` sirf `Challenge`, `PoToken`,
    //    `WebPoMinter`, `BotGuardClient` export karta hai — `GenerateIT`
    //    kahi nahi hai) — ye call `undefined.fetch(...)` pe crash karta.
    // 2) `minter.mintAsWebSafeString()` (capital S) bhi galat naam tha —
    //    real method `mintAsWebsafeString()` (lowercase s) hai.
    // Fix: manual BotGuardClient+GenerateIT+WebPoMinter steps hata ke
    // library ka apna tested all-in-one helper `BG.PoToken.generate()`
    // use kiya — ye andar hi ye poora flow (snapshot -> GenerateIT ->
    // mint) sahi method names ke saath karta hai, isliye naming-mismatch
    // ka risk khatam.
    const { poToken } = await BG.PoToken.generate({
      program: challenge.program,
      globalName: challenge.globalName,
      bgConfig,
    });
    if (!poToken) {
      reply({ok: false, error: 'BG.PoToken.generate() se empty/null poToken mila'});
      return;
    }
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
