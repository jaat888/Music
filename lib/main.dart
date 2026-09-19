// lib/main.dart
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'services/app_logger.dart';
import 'services/audio_focus_service.dart';
import 'services/background_service.dart';
import 'services/cache_service.dart';
import 'services/download_queue_service.dart';
import 'services/like_service.dart';
import 'services/potoken_service.dart';
import 'services/queue_service.dart';
import 'services/radio_history_store.dart';
import 'services/radio_service.dart';
import 'services/search_history.dart';
import 'services/sleep_timer_service.dart';
import 'services/theme_service.dart';
import 'theme/app_theme.dart';
import 'theme/colors.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';

String? _startupError;

// BUG FIX: playback fail hone pe (e.g. YouTube se koi audio stream resolve
// nahi hua) user ko koi feedback nahi milta tha — is global key se hum kahin
// se bhi (audioHandler ke andar se, kisi bhi screen pe) ek SnackBar dikha
// sakte hain.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

// Navigator key MaterialApp ke bina context pass kiye kahin se bhi
// navigate karne ke liye use hota hai.
final navigatorKey = GlobalKey<NavigatorState>();

// APP-WIDE LOGGING (2026-09-16): poori app ko ek custom Zone ke andar run
// karte hain jiska `print` handler override hai. Is wajah se codebase me
// jahan bhi `print(...)` / `debugPrint(...)` calls hain (youtube_service.dart,
// background_service.dart, waghera — 60+ jagah) unme se EK bhi line chhuye
// bina, sab automatically AppLogger me (aur isliye disk pe ek file me) save
// ho jaate hain. Saath hi Flutter framework errors (FlutterError.onError),
// aur async Zone ke bahar ke uncaught errors (PlatformDispatcher.onError)
// bhi yahi se pakde jaate hain. Ye native CrashLogger.kt se ALAG/extra hai —
// wo sirf native uncaught crash ke liye hai, ye poore app ke logs ke liye.
void main() {
  runZonedGuarded<void>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await AppLogger.instance.init();

    FlutterError.onError = (FlutterErrorDetails details) {
      AppLogger.instance.log(
        'FLUTTER ERROR: ${details.exceptionAsString()}\n${details.stack}',
        level: 'ERROR',
      );
      // Normal debug-console output (red screen etc.) bhi waisa hi rahe.
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      AppLogger.instance.log(
        'PLATFORM DISPATCHER ERROR: $error\n$stack',
        level: 'ERROR',
      );
      return true; // handled — process crash na ho
    };

    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);

      // Audio handler fail ho to bhi app crash na ho — sirf error store karo
      try {
        await initAudioHandler();
        audioHandler.onError = (message) {
          // BUG FIX (2026-09-18 — user report: "error wala message action-
          // buttons (Like/Download/Radio/...) ke bilkul chipak ke aata
          // hai, ganda lagta hai"): pehle ye default (fixed, full-width,
          // screen ke bilkul bottom se chipka) SnackBar tha — full player
          // screen pe wo action-row ke bilkul upar/uske saath overlap-jaisa
          // dikhta tha. Ab floating + margin, taaki hamesha thoda gap ho.
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.only(left: 16, right: 16, bottom: 96),
            ),
          );
        };
        // PART 2 (Sleep timer): "song khatam hone tak" mode fire hone par
        // audioHandler khud pause() kar chuka hota hai — ye sirf
        // SleepTimerService ka state/icon wapas "off" karta hai.
        audioHandler.onSleepAtEndOfTrackFired =
            SleepTimerService.instance.notifyEndOfTrackFired;

        double? volumeBeforeDuck;
        await AudioFocusService.configure(
          onCallPause: () => unawaited(audioHandler.pause()),
          onCallResume: () {},
          onDuck: (duck) {
            if (duck) {
              volumeBeforeDuck ??= audioHandler.player.volume;
              unawaited(audioHandler.player.setVolume(
                (audioHandler.player.volume * 0.35).clamp(0.0, 1.0).toDouble(),
              ));
            } else {
              final restore = volumeBeforeDuck;
              volumeBeforeDuck = null;
              if (restore != null) {
                unawaited(audioHandler.player.setVolume(restore));
              }
            }
          },
          onHeadphoneUnplug: () => unawaited(audioHandler.pause()),
        );
      } catch (e) {
        _startupError = 'Audio init failed: $e';
        AppLogger.instance.logError('Audio init failed', e, StackTrace.current);
      }

      await LikeService.instance.init();
      // PART 8 (Radio Mode) — Phase 2: app start pe history load + 4-6
      // mahine se purani entries purge (non-repeat window ka data layer).
      await RadioHistoryStore.instance.init();
      // PART 5 (Theme toggle): persisted theme mode ko sync cache me load
      // karo startup pe hi — MaterialApp.build() synchronously (bina async
      // gap ke) sahi theme choose kar sake (dekho theme_service.dart).
      await ThemeService.instance.init();

      // REMOVED (2026-09-18 — user report: "notification baar-baar neeche
      // se aati rehti hai, bekar hai"): pehle yahan ek GLOBAL listener tha
      // jo HAR single song ke download complete hone par ek SnackBar
      // dikhata tha — bulk queue (jaise "Downloads" screen se 5-10 gaane
      // ek saath download) me ye har gaane ke liye alag-alag baar-baar
      // popup hota rehta tha, aur Downloads screen already har gaane ka
      // progress/status inline dikhati hai, isliye ye pura redundant/
      // annoying tha. Ab silently hata diya — koi functionality nahi
      // ghati, sirf ye spam-y global toast hataya hai.
    } catch (e, st) {
      _startupError = 'Startup failed: $e';
      AppLogger.instance.logError('Startup failed', e, st);
    }

    runApp(const SurSathiApp());
  }, (error, stack) {
    // Zone ke andar kahin bhi uncaught async error — ye ho to bhi log ho
    // jaaye, app crash hone se pehle.
    AppLogger.instance.logError('UNCAUGHT ZONE ERROR', error, stack);
  }, zoneSpecification: ZoneSpecification(
    print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
      AppLogger.instance.log(line);
      // Normal console output bhi bana rahe (IDE/logcat me dikhta rahe).
      parent.print(zone, line);
    },
  ));
}

class SurSathiApp extends StatelessWidget {
  const SurSathiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: CacheService.instance),
        ChangeNotifierProvider.value(value: DownloadQueueService.instance),
        ChangeNotifierProvider.value(value: LikeService.instance),
        ChangeNotifierProvider.value(value: ThemeService.instance),
        ChangeNotifierProvider.value(value: QueueService.instance),
        ChangeNotifierProvider.value(value: RadioService.instance),
        ChangeNotifierProvider.value(value: SearchHistory.instance),
        ChangeNotifierProvider.value(value: SleepTimerService.instance),
      ],
      // PART 5 (2026-09-17) — Theme toggle (dark/light), ab real hai.
      // Consumer isliye taaki jab bhi `ThemeService.setThemeMode()` kahin
      // se (Settings screen) call ho, ye poora subtree turant rebuild ho.
      child: Consumer<ThemeService>(
        builder: (context, themeService, _) {
          // "System" mode ke liye device ka current brightness — MediaQuery
          // is level pe available nahi hai (MaterialApp abhi bana hi nahi),
          // isliye seedha platformDispatcher se (sync, context-independent).
          final systemBrightness =
              WidgetsBinding.instance.platformDispatcher.platformBrightness;
          final isLight = themeService.mode == ThemeMode.light ||
              (themeService.mode == ThemeMode.system &&
                  systemBrightness == Brightness.light);
          // colors.dart ke saare kBg/kText/kSurface/... getters isi flag ko
          // padhte hain — poore app me kahin bhi individually
          // Theme.of(context) refactor kiye bina, sirf is ek flag se
          // dark/light palette switch ho jaata hai.
          AppColorTheme.isLight = isLight;

          return MaterialApp(
            // Theme changes rebuild ThemeData without resetting Navigator state.
            title: 'SurSathi',
            navigatorKey: navigatorKey,
            scaffoldMessengerKey: scaffoldMessengerKey,
            debugShowCheckedModeBanner: false,
            theme: isLight ? AppTheme.light() : AppTheme.dark(),
            home: _startupError != null
                ? _ErrorScreen(error: _startupError!)
                : const _Boot(),
            // NEW (2026-09-17): PoToken (BotGuard) mint karne wala hidden
            // WebView — har screen ke upar Stack me 1x1 offstage mount rehta
            // hai poori app-lifetime, taaki youtube_service.dart jab bhi
            // PoTokenService.instance.getSessionPoToken() maange, WebView ka
            // JS engine already chal raha ho (Android WebView bina actual
            // View ke reliably JS nahi chalata). Dekho potoken_service.dart.
            builder: (context, child) => Stack(
              children: [
                if (child != null) child,
                const _PoTokenHost(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PoTokenHost extends StatelessWidget {
  const _PoTokenHost();
  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: true,
      child: SizedBox(
        width: 1,
        height: 1,
        child: WebViewWidget(controller: PoTokenService.instance.controller),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  final String error;
  const _ErrorScreen({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('STARTUP ERROR',
                    style: TextStyle(
                        color: Colors.red,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Text(error, style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Boot extends StatefulWidget {
  const _Boot({super.key});
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  bool? _onboarded;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _onboarded = prefs.getBool('onboarding_done') ?? false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded == null) {
      return Scaffold(backgroundColor: kBg, body: SizedBox.shrink());
    }
    return _onboarded! ? const HomeScreen() : const SplashScreen();
  }
}
