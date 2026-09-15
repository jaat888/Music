// lib/theme/typography.dart
// Saare text styles yahan se milenge. Sora = headings/display, Inter = body.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'colors.dart';

class AppText {
  AppText._();

  // ---------- Display styles (Sora, bold headers) ----------

  static TextStyle displayXL({Color color = kText}) => GoogleFonts.sora(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        color: color,
        height: 1.15,
        letterSpacing: -0.5,
      );

  static TextStyle displayL({Color color = kText}) => GoogleFonts.sora(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: color,
        height: 1.18,
        letterSpacing: -0.4,
      );

  static TextStyle displayM({Color color = kText}) => GoogleFonts.sora(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.2,
        letterSpacing: -0.2,
      );

  static TextStyle displayS({Color color = kText}) => GoogleFonts.sora(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.25,
      );

  // ---------- Body styles (Inter) ----------

  static TextStyle bodyL({Color color = kText}) => GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: color,
        height: 1.4,
      );

  static TextStyle bodyM({Color color = kTextDim}) => GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: color,
        height: 1.4,
      );

  static TextStyle bodyS({Color color = kTextDim}) => GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: color,
        height: 1.35,
      );

  // ---------- Utility styles ----------

  // Small caps-ish labels — section headers ke andar, chips me
  static TextStyle label({Color color = kTextDim}) => GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 0.6,
      );

  // Buttons ke andar text
  static TextStyle button({Color color = kText}) => GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 0.2,
      );

  /// Poora TextTheme banane ke liye — AppTheme me use hoga
  static TextTheme textTheme() {
    return TextTheme(
      displayLarge: displayXL(),
      displayMedium: displayL(),
      displaySmall: displayM(),
      headlineMedium: displayS(),
      bodyLarge: bodyL(),
      bodyMedium: bodyM(),
      bodySmall: bodyS(),
      labelLarge: button(),
      labelMedium: label(),
    );
  }
}
