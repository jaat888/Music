// lib/theme/colors.dart
// Saare app colors yahan se aate hai. Kahin bhi hardcode mat karna, isi file se import karna.
//
// PART 5 (2026-09-17) — Theme toggle (dark/light) ab REAL hai. Pehle
// kBg/kBgElev/kSurface/kText/kTextDim top-level `const Color` the — matlab
// poore app me hardcoded DARK values the, ThemeService.setThemeMode('light')
// select karne ka koi visual effect hi nahi tha (dekho NOTES.md #26 pattern
// — bahut saari settings sirf SharedPreferences-only thi). Ab ye 5 tokens
// getters hain jo `AppColorTheme.isLight` flag ke hisaab se dark/light
// palette choose karte hain. `main.dart` ka `SurSathiApp` is flag ko
// `ThemeService.mode` (+ system brightness) se sync rakhta hai aur toggle
// hone par `MaterialApp` ko naye `key` se poora rebuild karta hai (Navigator
// stack fresh ho jaata hai, Home pe aa jaayega) — taaki poore app me sab
// jagah naya theme turant, correctly apply ho, bina har screen ko
// individually `Theme.of(context)`-based refactor kiye. Accent colors
// (kGreen/kBlue/kPurple) aur status color (kRed) brand colors hain, dono
// themes me same rehte hain — const hi hain.
import 'package:flutter/material.dart';

class _Palette {
  final Color bg, bgElev, surface, text, textDim;
  const _Palette({
    required this.bg,
    required this.bgElev,
    required this.surface,
    required this.text,
    required this.textDim,
  });
}

const _darkPalette = _Palette(
  bg: Color(0xFF0A1428),
  bgElev: Color(0xFF142850),
  surface: Color(0xFF1E3A5F),
  text: Colors.white,
  textDim: Color(0xFFA0B0C8),
);

const _lightPalette = _Palette(
  bg: Color(0xFFF6F7FB),
  bgElev: Color(0xFFFFFFFF),
  surface: Color(0xFFE7EAF2),
  text: Color(0xFF10131A),
  textDim: Color(0xFF5B6472),
);

/// Global flag jo abhi kaunsa palette active hai batata hai. `main.dart`
/// har build me isko `ThemeService.mode` (+ system brightness agar mode
/// "system" hai) ke hisaab se sync karta hai, MaterialApp ko rebuild karne
/// se pehle — isliye kBg/kText waghera hamesha up-to-date value dete hain.
class AppColorTheme {
  AppColorTheme._();
  static bool isLight = false;
}

// ---------- Base colors (theme-reactive) ----------
Color get kBg => AppColorTheme.isLight ? _lightPalette.bg : _darkPalette.bg;
Color get kBgElev =>
    AppColorTheme.isLight ? _lightPalette.bgElev : _darkPalette.bgElev;
Color get kSurface =>
    AppColorTheme.isLight ? _lightPalette.surface : _darkPalette.surface;

// ---------- Text colors (theme-reactive) ----------
Color get kText => AppColorTheme.isLight ? _lightPalette.text : _darkPalette.text;
Color get kTextDim =>
    AppColorTheme.isLight ? _lightPalette.textDim : _darkPalette.textDim;

// ---------- Accent colors (brand — dono theme me same) ----------
const Color kGreen = Color(0xFF1DB954); // play button, success, liked
const Color kBlue = Color(0xFF1E90FF); // links, secondary accent
const Color kPurple = Color(0xFF7C6CF0); // gradients, highlights

// ---------- Status ----------
const Color kRed = Color(0xFFFF6B81); // errors, delete, heart-filled ke against use nahi (heart green hai)

/// Gradient presets — poore app me consistent gradients ke liye
class AppGradients {
  AppGradients._();

  // Play button, active states ke liye
  static const LinearGradient greenBlue = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [kGreen, kBlue],
  );

  // Headers, hero sections, splash ke liye
  static const LinearGradient bluePurple = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [kBlue, kPurple],
  );

  // Background ke upar subtle depth ke liye — kBgElev/kBg ab dynamic hain,
  // isliye ye ab getter hai (pehle `const` tha).
  static LinearGradient get bgFade => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [kBgElev, kBg],
      );

  // Card overlay (image ke upar text readable karne ke liye)
  static LinearGradient darkOverlay({double opacity = 0.85}) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withValues(alpha: 0.0),
          Colors.black.withValues(alpha: opacity),
        ],
      );
}

/// Radial glow helper — splash screen, active vinyl, pulse effects ke liye
class AppGlow {
  AppGlow._();

  /// Ek soft radial glow BoxDecoration deta hai. [color] ke around blur.
  static BoxDecoration radial({
    required Color color,
    double radius = 200,
    double opacity = 0.35,
  }) {
    return BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [
          color.withValues(alpha: opacity),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
        radius: 0.5,
      ),
    );
  }

  /// BoxShadow list — buttons/cards pe glow lagane ke liye (elevation jaisa but colored)
  static List<BoxShadow> shadow({
    required Color color,
    double blur = 24,
    double spread = 0,
    double opacity = 0.4,
  }) {
    return [
      BoxShadow(
        color: color.withValues(alpha: opacity),
        blurRadius: blur,
        spreadRadius: spread,
      ),
    ];
  }
}
