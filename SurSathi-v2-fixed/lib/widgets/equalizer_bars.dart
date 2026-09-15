// lib/widgets/equalizer_bars.dart
// Playing indicator — animated bars jab song chal raha ho, warna static chhote bars.

import 'package:flutter/material.dart';

import '../theme/colors.dart';

class EqualizerBars extends StatefulWidget {
  final Color color;
  final double size;
  final int barCount;
  final bool isPlaying;

  const EqualizerBars({
    super.key,
    this.color = kGreen,
    this.size = 22,
    this.barCount = 3,
    required this.isPlaying,
  });

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();
    // Har bar ka apna controller — thoda alag duration taaki natural lage
    _controllers = List.generate(widget.barCount, (i) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 400 + i * 150),
      );
    });
    _animations = _controllers
        .map(
          (c) => Tween<double>(begin: 6, end: widget.size).animate(
            CurvedAnimation(parent: c, curve: Curves.easeInOut),
          ),
        )
        .toList();

    if (widget.isPlaying) _startAnimating();
  }

  void _startAnimating() {
    for (final c in _controllers) {
      c.repeat(reverse: true);
    }
  }

  void _stopAnimating() {
    for (final c in _controllers) {
      c.stop();
      c.reset();
    }
  }

  @override
  void didUpdateWidget(covariant EqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      widget.isPlaying ? _startAnimating() : _stopAnimating();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(widget.barCount, (i) {
          return AnimatedBuilder(
            animation: _animations[i],
            builder: (context, child) {
              // Playing nahi hai to bars chhote static rahenge
              final height = widget.isPlaying ? _animations[i].value : 6.0;
              return Container(
                width: 3,
                height: height,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
