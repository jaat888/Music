// lib/widgets/loading_ring.dart
// Play/pause button ke around ghumne wala loading ring — jab gaana change
// hone ke baad load ho raha ho (timestamp 00:00, processingState loading/
// buffering) to ye ring dikhta hai aur button ke taps ko absorb kar leta
// hai, taaki user loading ke beech mein button ko baar-baar chhed na sake.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

class LoadingRing extends StatefulWidget {
  final bool isLoading;
  final double size;
  final Widget child;

  const LoadingRing({
    super.key,
    required this.isLoading,
    required this.child,
    this.size = 70,
  });

  @override
  State<LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<LoadingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isLoading) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant LoadingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading != oldWidget.isLoading) {
      widget.isLoading ? _controller.repeat() : _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ring button se thoda bada hota hai taaki border ke around ghume,
    // button ko khud chhote/bade na kare.
    final ringSize = widget.size + 16;

    return SizedBox(
      width: ringSize,
      height: ringSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Loading ke time button dim/disabled jaisa dikhe
          AnimatedOpacity(
            opacity: widget.isLoading ? 0.45 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: widget.child,
          ),
          if (widget.isLoading)
            IgnorePointer(
              child: RotationTransition(
                turns: _controller,
                child: CustomPaint(
                  size: Size(ringSize, ringSize),
                  painter: _RingPainter(),
                ),
              ),
            ),
          // Sabse upar ek transparent, opaque-hit-test blocker — jab tak
          // loading hai tab tak button tak tap pahunchne hi nahi deta.
          if (widget.isLoading)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [
          kGreen.withValues(alpha: 0.0),
          kGreen,
          kBlue,
        ],
        stops: const [0.0, 0.2, 0.85],
      ).createShader(rect);

    canvas.drawArc(rect, 0, math.pi * 1.5, false, paint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => false;
}
