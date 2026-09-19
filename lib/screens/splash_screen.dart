// lib/screens/splash_screen.dart
// App ka opening intro — har baar app khulne par chalta hai (YouTube jaisa).
//
// "Welcome to SurSathi" ki awaaz (assets/audio/welcome.mp3) aur animation ek
// hi timeline par chalte hain. Awaaz ke har shabd/syllable ka exact onset
// (seconds me, mp3 ka apna time) neeche `_t*` constants me likha hai, aur
// voice ki asli loudness ka envelope `_kEnv` me bake hai — isliye waveform
// bars wahi dikhate hain jo awaaz me sunayi deta hai, koi guess nahi.
//
//   audio t   0.08  "Wel"    0.40 "come"   0.67 "to"
//             0.90  "Sur"    1.19 "Sa"     1.41 "thi"   (awaaz 1.64 pe khatam)
//
// Tap karke skip kar sakte ho. Audio load/play fail ho to bhi animation
// chalti hai (silent) aur app normal khulta hai.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_screen.dart';
import 'onboarding_screen.dart';

// ---------- Fixed splash palette (theme se independent, brand look) ----------
const Color _kNavy = Color(0xFF0A1428);
const Color _kNavyLift = Color(0xFF142850);
const Color _kGreenBrand = Color(0xFF1DB954);
const Color _kBlueBrand = Color(0xFF1E90FF);
const Color _kDim = Color(0xFFA0B0C8);

// ---------- Timeline (seconds) ----------
/// Logo pehle chup-chaap pop hota hai, uske baad awaaz shuru hoti hai.
const double _kLeadIn = 0.25;

/// Android audio output latency ka andaza — awaaz itna pehle trigger hoti hai
/// taaki speaker se nikalne ka time animation ke saath match kare.
const double _kOutputLatency = 0.08;

/// Total splash length (controller time).
const double _kTotal = 2.6;

// Awaaz ke onsets (mp3 time, seconds).
const double _tWel = 0.08;
const double _tCome = 0.40;
const double _tTo = 0.67;
const double _tSur = 0.90;
const double _tSa = 1.19;
const double _tThi = 1.41;
const double _tEnd = 1.64;

/// Voice loudness envelope, 20 ms per sample (0..1), mp3 ke asli audio se.
const double _kEnvStep = 0.02;
const List<double> _kEnv = [
  0.00, 0.00, 0.00, 0.05, 0.23, 0.51, 0.79, 0.94, 0.98, 0.98, 0.97, 0.95,
  0.90, 0.84, 0.80, 0.71, 0.45, 0.13, 0.13, 0.34, 0.51, 0.75, 0.90, 0.88,
  0.87, 0.90, 0.90, 0.87, 0.82, 0.63, 0.28, 0.05, 0.15, 0.40, 0.56, 0.74,
  0.82, 0.67, 0.43, 0.26, 0.19, 0.15, 0.19, 0.24, 0.44, 0.80, 0.98, 0.98,
  0.99, 0.99, 0.97, 0.94, 0.84, 0.66, 0.47, 0.31, 0.26, 0.31, 0.38, 0.56,
  0.81, 0.90, 0.85, 0.79, 0.76, 0.69, 0.45, 0.13, 0.00, 0.10, 0.27, 0.29,
  0.25, 0.32, 0.43, 0.47, 0.44, 0.38, 0.32, 0.29, 0.30, 0.28, 0.18, 0.05,
  0.00, 0.00,
];

/// Audio-time `t` par voice ki loudness (0..1). t<0 ya end ke baad 0.
double _env(double t) {
  if (t <= 0) return 0;
  final x = t / _kEnvStep;
  final i = x.floor();
  if (i >= _kEnv.length - 1) return 0;
  final f = x - i;
  return _kEnv[i] * (1 - f) + _kEnv[i + 1] * f;
}

/// `start` se `dur` seconds me 0→1 (curve ke saath), uske pehle 0, baad 1.
double _seg(double t, double start, double dur, [Curve curve = Curves.linear]) {
  return curve.transform(((t - start) / dur).clamp(0.0, 1.0).toDouble());
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final AudioPlayer _player = AudioPlayer();

  bool _audioReady = false;
  bool _voiceStarted = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_kTotal * 1000).round()),
    );
    _ctrl.addListener(_maybeStartVoice);
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) _goNext();
    });
    unawaited(_run());
  }

  Future<void> _prepareAudio() async {
    try {
      await _player.setAsset('assets/audio/welcome.mp3');
      await _player.setVolume(1.0);
      _audioReady = true;
    } catch (e) {
      debugPrint('Splash audio load failed: $e');
    }
  }

  Future<void> _prepareFont() async {
    try {
      // Font beech animation me swap na ho, isliye pehle load karwa lete hain.
      await GoogleFonts.pendingFonts([
        GoogleFonts.sora(fontWeight: FontWeight.w800),
        GoogleFonts.sora(fontWeight: FontWeight.w500),
      ]);
    } catch (_) {}
  }

  Future<void> _run() async {
    // Audio + font ready hone tak (max 0.9s) ruko, phir dono ek saath shuru.
    // Isse awaaz aur animation ka sync har phone par same rehta hai.
    await Future.wait<void>([_prepareAudio(), _prepareFont()])
        .timeout(const Duration(milliseconds: 900), onTimeout: () => <void>[]);
    if (!mounted) return;
    _ctrl.forward();
  }

  void _maybeStartVoice() {
    if (_voiceStarted) return;
    final c = _ctrl.value * _kTotal;
    if (c >= _kLeadIn - _kOutputLatency) {
      _voiceStarted = true;
      if (_audioReady) {
        unawaited(_player.play().catchError((Object _) {}));
      }
    }
  }

  Future<void> _goNext() async {
    if (_navigated) return;
    _navigated = true;
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('onboarding_done') ?? false;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(_fadeRoute(done));
  }

  Route<void> _fadeRoute(bool onboardingDone) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, __, ___) =>
          onboardingDone ? const HomeScreen() : const OnboardingScreen(),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _player.dispose();
    super.dispose();
  }

  // ---------- Building blocks ----------

  /// Ek shabd/syllable jo apne onset par pop hokar aata hai.
  Widget _piece(
    String text,
    TextStyle style,
    double t,
    double onset, {
    double rise = 14,
    double dur = 0.16,
  }) {
    final start = onset - 0.03;
    final p = _seg(t, start, dur, Curves.easeOutBack);
    final o = _seg(t, start, dur * 0.7, Curves.easeOut);
    return Opacity(
      opacity: o,
      child: Transform.translate(
        offset: Offset(0, (1 - p) * rise),
        child: Transform.scale(
          scale: 0.86 + 0.14 * p,
          child: Text(text, style: style),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final smallStyle = GoogleFonts.sora(
      fontSize: 20,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.2,
      color: _kDim,
    );
    final bigStyle = GoogleFonts.sora(
      fontSize: 54,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      color: Colors.white,
      height: 1.1,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _kNavy,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _goNext,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_kNavy, _kNavyLift, _kNavy],
              ),
            ),
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                final c = _ctrl.value * _kTotal; // controller time
                final t = c - _kLeadIn; // mp3 (audio) time
                final logoPop = _seg(c, 0.0, 0.6, Curves.elasticOut);
                final e = _env(t);
                final logoScale = logoPop * (1 + 0.07 * e);
                final barsIn = _seg(c, 0.10, 0.30, Curves.easeOut);
                final tagIn = _seg(t, _tEnd + 0.06, 0.35, Curves.easeOut);

                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo + ripple rings (awaaz ke beats par)
                      SizedBox(
                        width: 220,
                        height: 220,
                        child: CustomPaint(
                          painter: _RipplePainter(t),
                          child: Center(
                            child: Transform.scale(
                              scale: logoScale,
                              child: Container(
                                width: 118,
                                height: 118,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const RadialGradient(
                                    colors: [_kGreenBrand, _kBlueBrand],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _kGreenBrand.withValues(
                                        alpha: 0.28 + 0.5 * e,
                                      ),
                                      blurRadius: 30 + 22 * e,
                                      spreadRadius: 4 + 6 * e,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.music_note,
                                  color: Colors.white,
                                  size: 60,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // "Welcome to" — Wel / come / to apne onset par
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _piece('Wel', smallStyle, t, _tWel, rise: 8),
                          _piece('come', smallStyle, t, _tCome, rise: 8),
                          const SizedBox(width: 8),
                          _piece('to', smallStyle, t, _tTo, rise: 8),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // "SurSathi" — Sur / Sa / thi apne onset par
                      ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (rect) => const LinearGradient(
                          colors: [_kGreenBrand, _kBlueBrand],
                        ).createShader(rect),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _piece('Sur', bigStyle, t, _tSur, rise: 20),
                              _piece('Sa', bigStyle, t, _tSa, rise: 20),
                              _piece('thi', bigStyle, t, _tThi, rise: 20),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 26),
                      // Voice waveform — asli awaaz ke envelope se
                      Opacity(
                        opacity: barsIn,
                        child: SizedBox(
                          width: 230,
                          height: 46,
                          child: CustomPaint(painter: _VoiceBarsPainter(t)),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Opacity(
                        opacity: tagIn,
                        child: Text(
                          'Apna music, apna style',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: _kDim,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Center se bahar failta hua voice waveform: har bar apni doori ke hisaab
/// se thoda late react karta hai, isliye awaaz "radiate" hoti dikhti hai.
class _VoiceBarsPainter extends CustomPainter {
  final double t;
  _VoiceBarsPainter(this.t);

  static const int _n = 27;

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 4.0;
    final gap = (size.width - _n * barW) / (_n - 1);
    final mid = (_n - 1) / 2;
    final cy = size.height / 2;
    for (var i = 0; i < _n; i++) {
      final d = (i - mid).abs();
      final e = _env(t - d * 0.028);
      final falloff = 1 - 0.55 * (d / mid);
      final h = 4 + e * (size.height - 4) * falloff;
      final x = i * (barW + gap);
      final color = Color.lerp(_kGreenBrand, _kBlueBrand, i / (_n - 1))!;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, cy - h / 2, barW, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_VoiceBarsPainter old) => old.t != t;
}

/// Logo ke around failti rings — "Wel", "Sur" aur "thi" ke onset par.
class _RipplePainter extends CustomPainter {
  final double t;
  _RipplePainter(this.t);

  // (onset, strength)
  static const _beats = [(_tWel, 0.55), (_tSur, 0.7), (_tThi, 1.0)];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final beat in _beats) {
      final p = _seg(t, beat.$1, 0.6, Curves.easeOutCubic);
      if (p <= 0 || p >= 1) continue;
      final radius = 62 + p * (70 + 40 * beat.$2);
      final alpha = (1 - p) * 0.55 * beat.$2;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * (1 - p) + 0.5
        ..color = Color.lerp(_kGreenBrand, _kBlueBrand, p)!
            .withValues(alpha: alpha);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t;
}
