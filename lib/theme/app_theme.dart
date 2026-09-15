// lib/theme/app_theme.dart
// ThemeData yahan se banta hai. AppTheme.dark() ko MaterialApp me lagana.

import 'package:flutter/material.dart';
import 'colors.dart';
import 'typography.dart';

class AppTheme {
  AppTheme._();

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Inter',
    );

    final colorScheme = const ColorScheme.dark(
      primary: kGreen,
      secondary: kBlue,
      tertiary: kPurple,
      surface: kSurface,
      error: kRed,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: kText,
      onError: Colors.white,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: kBg,
      textTheme: AppText.textTheme(),

      // ---------- AppBar ----------
      appBarTheme: AppBarThemeData(
        backgroundColor: kBg,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AppText.displayS(),
        iconTheme: const IconThemeData(color: kText),
        systemOverlayStyle: null, // main.dart me SystemChrome se set hoga
      ),

      // ---------- Card ----------
      cardTheme: CardThemeData(
        color: kBgElev,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),

      // ---------- Input fields (search bar, forms) ----------
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: kSurface,
        hintStyle: AppText.bodyM(color: kTextDim),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: kGreen, width: 1.5),
        ),
      ),

      // ---------- Buttons ----------
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: kGreen,
          foregroundColor: Colors.black,
          textStyle: AppText.button(color: Colors.black),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          elevation: 0,
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: kText,
          textStyle: AppText.button(),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: kText,
          side: const BorderSide(color: kTextDim, width: 1),
          textStyle: AppText.button(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: kText),
      ),

      // ---------- SnackBar ----------
      snackBarTheme: SnackBarThemeData(
        backgroundColor: kBgElev,
        contentTextStyle: AppText.bodyM(color: kText),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      // ---------- BottomSheet ----------
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: kBgElev,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),

      // ---------- Slider (progress bar, volume) ----------
      sliderTheme: SliderThemeData(
        activeTrackColor: kGreen,
        inactiveTrackColor: kSurface,
        thumbColor: kText,
        overlayColor: kGreen.withValues(alpha: 0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),

      // ---------- Progress indicator ----------
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: kGreen,
        linearTrackColor: kSurface,
        circularTrackColor: kSurface,
      ),

      // ---------- BottomNavigationBar ----------
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: kBgElev,
        selectedItemColor: kGreen,
        unselectedItemColor: kTextDim,
        selectedLabelStyle: AppText.label(color: kGreen),
        unselectedLabelStyle: AppText.label(color: kTextDim),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      // ---------- NavigationBar (Material 3 style) ----------
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: kBgElev,
        indicatorColor: kGreen.withValues(alpha: 0.2),
        labelTextStyle: WidgetStateProperty.all(AppText.label()),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),

      // ---------- Divider ----------
      dividerTheme: DividerThemeData(
        color: kSurface,
        thickness: 1,
        space: 1,
      ),

      // ---------- Dialog ----------
      dialogTheme: DialogThemeData(
        backgroundColor: kBgElev,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AppText.displayS(),
        contentTextStyle: AppText.bodyM(color: kText),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),

      // ---------- Chip (category filters, tags) ----------
      chipTheme: ChipThemeData(
        backgroundColor: kSurface,
        selectedColor: kGreen,
        labelStyle: AppText.bodyS(color: kText),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),

      // ---------- Switch (settings screen) ----------
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? kGreen : kTextDim,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? kGreen.withValues(alpha: 0.4)
              : kSurface,
        ),
      ),
    );
  }
}
