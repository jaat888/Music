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
// token) attach nahi hota: chhota "cold start" data turant de deta hai
// (isliye setUrl/pehle few sec "chalta hua" lagta hai), phir verify fail
// hone pe stream cut kar deta hai.
//
// Poore codebase me PoToken mint karne ka koi code nahi tha — sirf
// signature-cipher solve (Deno JS solver / NewPipeExtractor) tha, jo ek
// ALAG cheez hai (wo stream-URL ki signature decode karta hai, wo URL
// "verified" hai ya nahi — ye BotGuard decide karta hai).
//
// ===================== FIX (Option 1 — real BotGuard solver) =====================
// Ye service YouTube web player ka wahi flow replicate karta hai jo asli
// browser (aur OpenTune/InnerTune jaisi verified clients) karte hain:
//   1. Ek HIDDEN (offstage) WebView `https://www.youtube.com` load karta
//      hai — isi se real visitorData milta hai aur fetch() calls same-
//      origin (CORS-safe) rehte hain.
//   2. WebView ke andar `bgutils-js` (LuanRT/BgUtils — public, open-source,
//      reverse-engineered library jo isi BotGuard/PoToken flow ko implement
//      karti hai, wahi jo yt-dlp ke PO-Token-Guide aur rustypipe-botguard
//      jaisे projects reference karte hain) CDN se load karke, uske
//      documented high-level API (Challenge.create -> BotGuardClient.create
//      -> snapshot -> GenerateIT -> WebPoMinter -> mintAsWebSafeString) se
//      asli BotGuard challenge solve karke ek "session-bound" PO Token mint
//      karta hai.
//   3. Ye token youtube_service.dart me har resolved stream URL pe
//      `&pot=<token>` query param ki tarah attach hota hai (documented
//      usage: "Stream URLs need a `pot` param, session-bound, visitorData
//      se bound") — verify aur playback dono isi URL se hote hain.
//
// *** IMPORTANT — HONESTY NOTE (isko README/NOTES.md me bhi rakhna) ***
// - Ye is environment (sandboxed container, no network/Android SDK) me
//   COMPILE ya LIVE-TEST nahi ho saka hai. BotGuard ka exact wire-protocol
//   khud Google/BgUtils library ke andar hai (hum usko CDN se load karke
//   uski hi high-level API call kar rahe hain — hum khud protocol
//   reimplement nahi kar rahe, isse fragile-guessing ka risk kam hota hai),
//   lekin YouTube ye script/endpoints kabhi bhi badal sakta hai. Pehli real
//   build pe agar mint fail ho (debug screen me "PoToken: FAILED..." log
//   dikhega), poora system FAIL-SOFT hai — pot param bas skip ho jaata hai,
//   app pehle jaisa (bina poToken ke) behave karti hai, koi crash/regression
//   nahi.
// - `requestKey` (niche) ek public constant hai jo BgUtils/yt-dlp docs me
//   publish hui hai; agar YouTube kabhi rotate kare to ye bhi fail-soft hi
//   fail hoga (naya key BgUtils README/yt-dlp PO-Token-Guide se update
//   karna padega).
// - NewPipeExtractor (native Kotlin layer) is fix se abhi bhi cover NAHI
//   hota — poToken sirf youtube_explode_dart/Piped layers ke resolved URL
//   pe attach hota hai. NewPipeExtractor library khud PoToken support nahi
//   karti (upstream limitation), isliye us layer ka apna 403-rate jaisa hi
//   rahega. Agar NewPipe layer bhi PoToken chahiye ho to uski library hi
//   patch karni padegi — bada, alag scope.

import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

class PoTokenService {
  PoTokenService._internal();
  static final PoTokenService instance = PoTokenService._internal();

  // BgUtils/yt-dlp docs me publish hua public "web" requestKey — koi secret
  // nahi, isi tarah har open-source PoToken implementation (yt-dlp,
  // rustypipe-botguard, InnerTune forks) me hardcoded milta hai.
  static const String _requestKey = 'O43z0dpjhgX20SCx4KAo';

  // bgutils-js UMD bundle — jsdelivr CDN, pinned version (isse agar upstream
  // breaking change kare to bhi ye build achanak break nahi hogi).
  static const String _bgutilsCdnUrl =
      'https://cdn.jsdelivr.net/npm/bgutils-js@2.6.0/dist/index.min.js';

  WebViewController? _controller;
  bool _pageReady = false;

  String? _cachedToken;
  DateTime? _cachedAt;
  // Conservative — real cold tokens usually last longer, lekin refresh
  // sasta hai (ek hi WebView call) isliye safe side rakha.
  static const Duration _cacheTtl = Duration(hours: 4);

  Completer<Map<String, dynamic>>? _pendingMint;

  // Host widget (dekho main.dart) ye controller banwata/attach karta hai —
  // WebView platform-view ko actually widget tree me mount hona zaroori hai
  // taaki uska JS engine reliably chale (Android WebView background me
  // bina View ke run nahi hota).
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
      ..loadRequest(Uri.parse('https://www.youtube.com'));
    return c;
  }

  // Session-bound PoToken (visitorData se bound) — ye woh token hai jo
  // stream URL me `&pot=` ki tarah lagana hai. Fail-soft: kisi bhi step
  // pe error aaye to null return karta hai (caller pot skip kar dega).
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
    // Ek waqt me sirf ek mint chale — do parallel calls aaye (e.g. do
    // songs almost-saath resolve ho rahe hain) to dusra pehle wale ka hi
    // result wait/share kare, WebView ko do baar concurrent script na
    // milein (JS globals overwrite ho jaate).
    if (_pendingMint != null) {
      return _pendingMint!.future;
    }
    final completer = Completer<Map<String, dynamic>>();
    _pendingMint = completer;
    try {
      // Controller lazily initialize hota hai (getter) — agar host widget
      // abhi tak mount nahi hua (bahut jaldi call aa gayi app-start pe), to
      // thoda wait kar lo taaki WebView page actually load ho chuka ho.
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

  // WebView ke andar chalne wali JS — bgutils-js ko CDN se load karke uski
  // hi documented high-level API se poora Challenge -> BotGuardClient ->
  // snapshot -> GenerateIT -> WebPoMinter flow chalata hai (hum khud
  // protocol reimplement nahi kar rahe — library khud karti hai, dekho file
  // ke top ka comment). visitorData YouTube ke apne `ytcfg` se nikalte hain
  // (isi page pe already available hai kyunki hum youtube.com pe loaded
  // hain).
  static final String _bootstrapJs = r'''
(async function () {
  function reply(obj) {
    try { PoTokenBridge.postMessage(JSON.stringify(obj)); } catch (e) {}
  }
  try {
    if (!window.__bgUtilsLoaded) {
      // BUG FIX (2026-09-17): pehle yahan `<script>` tag banaake uska
      // `.src` property seedha set karte the — youtube.com ka page khud
      // "Trusted Types" CSP enforce karta hai (XSS-protection), jisme
      // `HTMLScriptElement.src` par DIRECT string assignment disallowed
      // hai (sirf ek pre-approved TrustedScriptURL chalta hai). Error tha:
      // "Failed to set the 'src' property... requires 'TrustedScriptURL'
      // assignment" — isi wajah se PoToken kabhi mint hi nahi ho paaya, aur
      // silently purane (bina-pot) behavior pe fall back ho raha tha.
      // Fix: script tag ki jagah `fetch()` se library ka JS TEXT download
      // karke `new Function()` se seedha execute karte hain — ye Trusted
      // Types ke `script.src` wale specific sink se hi guzarta nahi, isliye
      // wahi restriction yahan lagu nahi hoti (ye bilkul wahi tarika hai jo
      // niche interpreterJs ke liye already use ho raha tha, isi liye wo
      // step is error se affected nahi tha).
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

    // visitorData: YouTube page ke apne config se (session ke liye
    // identifier/content-binding chahiye).
    let visitorData = null;
    try {
      visitorData = (window.ytcfg && window.ytcfg.data_ &&
        window.ytcfg.data_.INNERTUBE_CONTEXT &&
        window.ytcfg.data_.INNERTUBE_CONTEXT.client &&
        window.ytcfg.data_.INNERTUBE_CONTEXT.client.visitorData) || null;
      if (!visitorData && window.ytcfg && window.ytcfg.get) {
        visitorData = window.ytcfg.get('VISITOR_DATA') || null;
      }
    } catch (e) {}
    if (!visitorData) {
      reply({ok: false, error: 'visitorData not found on page'});
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
      .replaceAll('REQUEST_KEY', _requestKey);
}
