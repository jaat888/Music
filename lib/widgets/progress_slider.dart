// lib/widgets/progress_slider.dart
// Player ka seek bar — position/total time labels ke saath.
//
// NEW: `bufferedPosition` — chunked streaming (dekho
// chunked_audio_source.dart) me "kitna load ho chuka hai" dikhna zaroori
// hai (user request: "seek line mein chunk aaya kitna aaya"), warna
// track mein pata hi nahi chalta ki abhi download-in-progress hai ya
// genuinely stall hua hai. Ek halka-shade bar buffered-tak dikhta hai,
// uske peeche track ke piche.

import 'package:flutter/material.dart';

import '../theme/colors.dart';

class ProgressSlider extends StatelessWidget {
  final Duration position;
  final Duration total;
  final ValueChanged<Duration> onSeek;
  final Color activeColor;
  final Duration? bufferedPosition;

  const ProgressSlider({
    super.key,
    required this.position,
    required this.total,
    required this.onSeek,
    this.activeColor = kGreen,
    this.bufferedPosition,
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
    final bufferedFraction = hasDuration && bufferedPosition != null
        ? (bufferedPosition!.inMilliseconds / maxMs).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // Buffered-progress bar — track ke exact height/position pe,
            // Slider ke peeche (halka shade, kitna load ho chuka hai).
            if (hasDuration && bufferedFraction > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: bufferedFraction,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white38,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: activeColor,
                // Buffered bar upar se dikhta rahe — is track ka apna
                // "inactive" hissa transparent rakha, warna buffered bar
                // ko dhak dega.
                inactiveTrackColor:
                    bufferedFraction > 0 ? Colors.transparent : Colors.white24,
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
          ],
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

