// lib/theme/typography.dart
// Saare text styles yahan se milenge. Sora = headings/display, Inter = body.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'colors.dart';

class AppText {
  static TextStyle titleL({Color? color}) => TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: color,
      );

  static TextStyle titleM({Color? color}) => TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: color,
      );

  AppText._();

  // ---------- Display styles (Sora, bold headers) ----------
  // BUG FIX (build break): `color` param pehle `{Color color = kText}`
  // tha — Part 5 (theme toggle) ke baad kText/kTextDim ab dynamic getters
  // hain (const nahi), aur Dart me default parameter value hamesha ek
  // compile-time CONSTANT honi chahiye. Isliye `{Color? color}` (null
  // default, khud constant hai) + andar `color ?? kText` pattern kiya.

  static TextStyle displayXL({Color? color}) => GoogleFonts.sora(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        color: color ?? kText,
        height: 1.15,
        letterSpacing: -0.5,
      );

  static TextStyle displayL({Color? color}) => GoogleFonts.sora(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: color ?? kText,
        height: 1.18,
        letterSpacing: -0.4,
      );

  static TextStyle displayM({Color? color}) => GoogleFonts.sora(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: color ?? kText,
        height: 1.2,
        letterSpacing: -0.2,
      );

  static TextStyle displayS({Color? color}) => GoogleFonts.sora(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: color ?? kText,
        height: 1.25,
      );

  // ---------- Body styles (Inter) ----------

  static TextStyle bodyL({Color? color}) => GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: color ?? kText,
        height: 1.4,
      );

  static TextStyle bodyM({Color? color}) => GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: color ?? kTextDim,
        height: 1.4,
      );

  static TextStyle bodyS({Color? color}) => GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: color ?? kTextDim,
        height: 1.35,
      );

  // ---------- Utility styles ----------

  // Small caps-ish labels — section headers ke andar, chips me
  static TextStyle label({Color? color}) => GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: color ?? kTextDim,
        letterSpacing: 0.6,
      );

  // Buttons ke andar text
  static TextStyle button({Color? color}) => GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: color ?? kText,
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
