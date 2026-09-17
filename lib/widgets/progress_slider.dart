// lib/widgets/progress_slider.dart
// Player ka seek bar — position/total time labels ke saath.

import 'package:flutter/material.dart';

import '../theme/colors.dart';

class ProgressSlider extends StatelessWidget {
  final Duration position;
  final Duration total;
  final ValueChanged<Duration> onSeek;
  final Color activeColor;

  const ProgressSlider({
    super.key,
    required this.position,
    required this.total,
    required this.onSeek,
    this.activeColor = kGreen,
  });

  // Duration ko "m:ss" format me convert karta hai
  String _format(Duration d) {
    final minutes = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = total.inMilliseconds;
    final hasDuration = maxMs > 0;
    // Total zero hone pe slider disabled rahega — divide-by-zero/crash na ho
    final currentMs = hasDuration
        ? position.inMilliseconds.clamp(0, maxMs).toDouble()
        : 0.0;

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: activeColor,
            inactiveTrackColor: Colors.white24,
            thumbColor: activeColor,
            trackHeight: 3,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: currentMs,
            max: hasDuration ? maxMs.toDouble() : 1.0,
            onChanged: hasDuration
                ? (value) => onSeek(Duration(milliseconds: value.round()))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(position), style: TextStyle(color: kTextDim, fontSize: 12)),
              Text(_format(total), style: TextStyle(color: kTextDim, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}
