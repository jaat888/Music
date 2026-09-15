// lib/screens/language_screen.dart
// Language chunne ka screen — Hindi / English / Haryanvi. Continue dabane pe
// SharedPreferences me save hota hai aur PermissionScreen pe navigate hota hai.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'permission_screen.dart';

class _LangOption {
  final String code;
  final String name;
  final String native;
  final String flag;

  const _LangOption(this.code, this.name, this.native, this.flag);
}

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  static const List<_LangOption> _langs = [
    _LangOption('hi', 'Hindi', 'हिंदी', '🇮🇳'),
    _LangOption('en', 'English', 'English', '🇬🇧'),
    _LangOption('hr', 'Haryanvi', 'हरियाणवी', '🎤'),
  ];

  String _selected = 'hi';

  Future<void> _continue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language', _selected);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(_fadeSlideRoute());
  }

  Route _fadeSlideRoute() {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, __, ___) => const PermissionScreen(),
      transitionsBuilder: (_, anim, __, child) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              Text('Apni bhasha chuno', style: AppText.displayL()),
              const SizedBox(height: 8),
              Text(
                'Baad me settings me badal sakte ho',
                style: AppText.bodyM(),
              ),
              const SizedBox(height: 28),
              Expanded(
                child: ListView(
                  children: _langs.map((lang) {
                    final isSelected = _selected == lang.code;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: GestureDetector(
                        onTap: () => setState(() => _selected = lang.code),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 18,
                          ),
                          decoration: BoxDecoration(
                            color: kBgElev,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected ? kGreen : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(lang.flag, style: const TextStyle(fontSize: 30)),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(lang.name, style: AppText.bodyL()),
                                  const SizedBox(height: 2),
                                  Text(lang.native, style: AppText.bodyS()),
                                ],
                              ),
                              const Spacer(),
                              if (isSelected)
                                const Icon(Icons.check_circle, color: kGreen),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGreen,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: _continue,
                  child: Text('Continue', style: AppText.button()),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
