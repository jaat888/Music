// lib/main.dart
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'services/app_logger.dart';
import 'services/background_service.dart';
import 'services/cache_service.dart';
import 'services/like_service.dart';
import 'services/potoken_service.dart';
import 'services/queue_service.dart';
import 'services/search_history.dart';
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
          scaffoldMessengerKey.currentState?.showSnackBar(
            SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
          );
        };
      } catch (e) {
        _startupError = 'Audio init failed: $e';
        AppLogger.instance.logError('Audio init failed', e, StackTrace.current);
      }

      await LikeService.instance.init();
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
        ChangeNotifierProvider.value(value: LikeService.instance),
        ChangeNotifierProvider.value(value: ThemeService.instance),
        ChangeNotifierProvider.value(value: QueueService.instance),
        ChangeNotifierProvider.value(value: SearchHistory.instance),
      ],
      child: MaterialApp(
        title: 'SurSathi',
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
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
      return const Scaffold(backgroundColor: kBg, body: SizedBox.shrink());
    }
    return _onboarded! ? const HomeScreen() : const SplashScreen();
  }
}
