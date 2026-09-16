// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:newpipeextractor_dart/newpipeextractor_dart.dart';

import 'services/background_service.dart';
import 'services/cache_service.dart';
import 'services/like_service.dart';
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

// NEW (2026-09-16, v4): newpipeextractor_dart ke liye — YouTube kabhi-kabhi
// automated requests pe reCAPTCHA maang leta hai. Isse solve karne ke liye
// package ek WebView-based ReCaptchaPage deta hai, jise open karne ke liye
// hume ek Navigator chahiye — is global key se hum MaterialApp ke bina
// context pass kiye kahin se bhi navigate kar sakte hain.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // NEW (2026-09-16, v4): ek baar app startup pe register karna hota hai —
  // jab bhi koi NewPipeExtractor call ReCaptchaRequiredException fenke,
  // package khud is callback ko bulayega challengeUrl ke saath.
  setReCaptchaNavigator((String challengeUrl) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    await Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => const ReCaptchaPage(),
        settings: RouteSettings(arguments: challengeUrl),
      ),
    );
  });

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
    }

    await LikeService.instance.init();
  } catch (e) {
    _startupError = 'Startup failed: $e';
  }

  runApp(const SurSathiApp());
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
