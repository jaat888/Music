// lib/widgets/heart_button.dart
// Reusable heart/like button — bounce animation ke saath.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';

class HeartButton extends StatefulWidget {
  final bool isLiked;
  final VoidCallback onTap;
  final double size;

  const HeartButton({
    super.key,
    required this.isLiked,
    required this.onTap,
    this.size = 26,
  });

  @override
  State<HeartButton> createState() => _HeartButtonState();
}

class _HeartButtonState extends State<HeartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    // Bounce: 1.0 -> 1.3 -> 1.0
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  void _handleTap() {
    HapticFeedback.mediumImpact();
    _controller.forward(from: 0);
    widget.onTap();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: ScaleTransition(
        scale: _scale,
        child: Icon(
          widget.isLiked ? Icons.favorite : Icons.favorite_border,
          color: widget.isLiked ? kRed : kTextDim,
          size: widget.size,
        ),
      ),
    );
  }
}
