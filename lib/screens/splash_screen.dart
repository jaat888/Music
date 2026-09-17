// lib/screens/splash_screen.dart
// App ka pehla screen — logo pop hota hai, glow pulse karta hai, text slide
// karke aata hai, fir 2 second baad SharedPreferences check karke ya to
// HomeScreen (agar onboarding pehle se ho chuki hai) ya OnboardingScreen
// (pehli baar) pe navigate hota hai.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _scaleCtrl;
  late final AnimationController _glowCtrl;
  late final AnimationController _textCtrl;

  late final Animation<double> _scaleAnim;
  late final Animation<double> _glowAnim;
  late final Animation<Offset> _textSlideAnim;
  late final Animation<double> _textFadeAnim;

  @override
  void initState() {
    super.initState();

    // Logo circle scale-in — elastic pop
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _scaleAnim = CurvedAnimation(parent: _scaleCtrl, curve: Curves.elasticOut);

    // Glow pulse — loop reverse, hamesha chalta rehta hai
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.35, end: 0.75).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );

    // Text slide-up + fade-in — 500ms delay ke baad shuru hota hai
    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _textSlideAnim = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _textCtrl, curve: Curves.easeOutCubic));
    _textFadeAnim = CurvedAnimation(parent: _textCtrl, curve: Curves.easeIn);

    _scaleCtrl.forward();

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _textCtrl.forward();
    });

    // 2000ms baad onboarding_done check karke fade transition ke saath
    // HomeScreen (already onboarded) ya OnboardingScreen (pehli baar) pe jaate hain
    Future.delayed(const Duration(milliseconds: 2000), () async {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getBool('onboarding_done') ?? false;
      if (!mounted) return;
      Navigator.of(context).pushReplacement(_fadeRoute(done));
    });
  }

  Route _fadeRoute(bool onboardingDone) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (_, __, ___) =>
          onboardingDone ? const HomeScreen() : const OnboardingScreen(),
      transitionsBuilder: (_, anim, __, child) {
        return FadeTransition(opacity: anim, child: child);
      },
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    _glowCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration:  BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [kBg, kBgElev, kBg],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([_scaleAnim, _glowAnim]),
                builder: (context, child) {
                  return Transform.scale(
                    scale: _scaleAnim.value,
                    child: Container(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(
                          colors: [kGreen, kBlue],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: kGreen.withValues(alpha: _glowAnim.value),
                            blurRadius: 40,
                            spreadRadius: 8,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.music_note,
                        color: Colors.white,
                        size: 65,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 32),
              SlideTransition(
                position: _textSlideAnim,
                child: FadeTransition(
                  opacity: _textFadeAnim,
                  child: Column(
                    children: [
                      Text(
                        'SurSathi',
                        style: GoogleFonts.sora(
                          fontSize: 44,
                          fontWeight: FontWeight.w800,
                          color: kGreen,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Apna music, apna style',
                        style: AppText.bodyM(color: kTextDim),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
