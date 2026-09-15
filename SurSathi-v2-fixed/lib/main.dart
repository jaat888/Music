// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Audio handler fail ho to bhi app crash na ho — sirf error store karo
    try {
      await initAudioHandler();
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
