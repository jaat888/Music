// lib/screens/taste_screen.dart
// User apni pasand ke music categories chunta hai (kam se kam 3). Save hone
// ke baad onboarding_done=true set hota hai aur real HomeScreen pe navigate
// hota hai — ye poori onboarding chain ka aakhri step hai.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'home_screen.dart';

class _TasteChipData {
  final String label;
  final String emoji;

  const _TasteChipData(this.label, this.emoji);
}

class TasteScreen extends StatefulWidget {
  const TasteScreen({super.key});

  @override
  State<TasteScreen> createState() => _TasteScreenState();
}

class _TasteScreenState extends State<TasteScreen> {
  static const List<_TasteChipData> _categories = [
    _TasteChipData('Bollywood', '🎬'),
    _TasteChipData('Punjabi', '🕺'),
    _TasteChipData('Haryanvi', '🎤'),
    _TasteChipData('Lo-Fi', '🌙'),
    _TasteChipData('Party', '🎉'),
    _TasteChipData('Romantic', '💕'),
    _TasteChipData('Workout', '💪'),
    _TasteChipData('Old Hits', '📻'),
    _TasteChipData('Arijit', '🎵'),
    _TasteChipData('Chill', '☕'),
    _TasteChipData('Devotional', '🕉'),
    _TasteChipData('Hip-Hop', '🎧'),
  ];

  final Set<String> _selected = {};

  void _toggle(String label) {
    setState(() {
      if (_selected.contains(label)) {
        _selected.remove(label);
      } else {
        _selected.add(label);
      }
    });
  }

  Future<void> _start() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('user_tastes', _selected.toList());
    await prefs.setBool('onboarding_done', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 450),
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(opacity: anim, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canStart = _selected.length >= 3;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              Text('Apni pasand chuno', style: AppText.displayM()),
              const SizedBox(height: 6),
              Text('Kam se kam 3 chuno', style: AppText.bodyM()),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.builder(
                  itemCount: _categories.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 2.6,
                  ),
                  itemBuilder: (context, index) {
                    final cat = _categories[index];
                    final isSelected = _selected.contains(cat.label);
                    return _TasteChip(
                      data: cat,
                      selected: isSelected,
                      onTap: () => _toggle(cat.label),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGreen,
                    disabledBackgroundColor: kSurface,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: canStart ? _start : null,
                  child: Text(
                    'Shuru karo',
                    style: AppText.button(color: canStart ? kText : kTextDim),
                  ),
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

class _TasteChip extends StatefulWidget {
  final _TasteChipData data;
  final bool selected;
  final VoidCallback onTap;

  const _TasteChip({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TasteChip> createState() => _TasteChipState();
}

class _TasteChipState extends State<_TasteChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: widget.selected ? kGreen.withValues(alpha: 0.15) : kBgElev,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.selected ? kGreen : Colors.transparent,
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(widget.data.emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.data.label,
                  style: AppText.bodyM(
                    color: widget.selected ? kText : kTextDim,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

