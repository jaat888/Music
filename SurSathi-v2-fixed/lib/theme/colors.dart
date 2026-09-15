// lib/theme/colors.dart
// Saare app colors yahan se aate hai. Kahin bhi hardcode mat karna, isi file se import karna.

import 'package:flutter/material.dart';

// ---------- Base colors ----------
const Color kBg = Color(0xFF0A1428); // sabse peeche wala background
const Color kBgElev = Color(0xFF142850); // thoda upar uthaya hua surface (cards, sheets)
const Color kSurface = Color(0xFF1E3A5F); // inputs, chips, list tiles

// ---------- Accent colors ----------
const Color kGreen = Color(0xFF1DB954); // play button, success, liked
const Color kBlue = Color(0xFF1E90FF); // links, secondary accent
const Color kPurple = Color(0xFF7C6CF0); // gradients, highlights

// ---------- Text colors ----------
const Color kText = Colors.white; // primary text
const Color kTextDim = Color(0xFFA0B0C8); // subtitle / secondary text

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

  // Background ke upar subtle depth ke liye
  static const LinearGradient bgFade = LinearGradient(
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
