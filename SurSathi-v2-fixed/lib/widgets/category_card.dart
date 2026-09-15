// lib/widgets/category_card.dart
// Home screen ki category tiles — gradient background + stagger entrance animation.

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

class CategoryCard extends StatefulWidget {
  final String name;
  final String emoji;
  final VoidCallback onTap;
  final int index; // stagger animation ke liye

  const CategoryCard({
    super.key,
    required this.name,
    required this.emoji,
    required this.onTap,
    required this.index,
  });

  @override
  State<CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<CategoryCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final isEven = widget.index % 2 == 0;
    final gradient = isEven ? AppGradients.greenBlue : AppGradients.bluePurple;
    final shadowColor = isEven ? kGreen : kBlue;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 300 + widget.index * 60),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        // Slide from left + fade in
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(20 * (1 - value), 0),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _scale = 0.95),
        onTapUp: (_) => setState(() => _scale = 1.0),
        onTapCancel: () => setState(() => _scale = 1.0),
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 100),
          child: Container(
            width: 115,
            height: 95,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: shadowColor.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.emoji, style: const TextStyle(fontSize: 22)),
                  const SizedBox(height: 6),
                  Text(
                    widget.name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyM(color: kText).copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
