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

// BUG FIX (2026-09-18, real-device log — exact timing proof): pehle ye
// StatelessWidget tha aur `Slider.onChanged` seedha `onSeek()` (asli
// `audioHandler.seek()`, ek network-buffering operation) call karta tha —
// matlab drag ke HAR pixel-move pe ek real seek fire hoti thi. Log me
// isi wajah se ek hi drag gesture ke dauraan 61ms ke andar 6 alag seek()
// calls dikhe (10:22:50.010 se 10:22:50.071) — har ek apna buffering
// cycle shuru karti, isliye drag karte waqt gaana atakta/stutter karta
// tha. `radio_player_screen.dart` ka apna slider ye SAHI tarike se karta
// hai (drag ke dauraan sirf local state update, seek sirf release pe ek
// baar) — yahi pattern copy kiya.
class ProgressSlider extends StatefulWidget {
  final Duration position;
  final Duration total;
  final ValueChanged<Duration> onSeek;
  final Color activeColor;
  final Duration? bufferedPosition;
  // BUG FIX (seekbar-loading-guard): jaisa play/pause button pe loading ke
  // dauraan taps guard kiye gaye the (dekho full_player_screen.dart ka
  // `isLoading` + LoadingRing), waisa hi ab seekbar ke saath bhi — jab
  // gaana abhi load/resolve ho raha ho, drag/tap se seek() call karna
  // galat/stale position pe seek kar sakta hai ya bilkul kaam nahi karega.
  // `enabled=false` hone par slider visually dim ho jaata hai aur
  // drag/tap dono ignore hote hain (thumb hilta hi nahi).
  final bool enabled;

  const ProgressSlider({
    super.key,
    required this.position,
    required this.total,
    required this.onSeek,
    this.activeColor = kGreen,
    this.bufferedPosition,
    this.enabled = true,
  });

  @override
  State<ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<ProgressSlider> {
  bool _dragging = false;
  double _dragMs = 0;

  // Duration ko "m:ss" format me convert karta hai
  String _format(Duration d) {
    final minutes = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = widget.total.inMilliseconds;
    final hasDuration = maxMs > 0;
    // Drag ke dauraan hamesha local `_dragMs` dikhao (warna stream se aane
    // wali purani `position` beech-beech me thumb ko wapas kheech legi) —
    // drag khatam hote hi wapas live `position` follow karta hai.
    final displayMs = _dragging
        ? _dragMs
        : (hasDuration
            ? widget.position.inMilliseconds.clamp(0, maxMs).toDouble()
            : 0.0);
    final rawBufferedMs = widget.bufferedPosition?.inMilliseconds ?? 0;
    final bufferedFraction = hasDuration
        ? (rawBufferedMs.clamp(0, maxMs) / maxMs).clamp(0.0, 1.0)
        : 0.0;
    // Loading ke dauraan drag allow hi nahi karte — `hasDuration` ke saath
    // AND karte hain taaki dono guards ek saath respect ho.
    final interactive = hasDuration && widget.enabled;

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
                // Loading ke dauraan track bhi dim dikhta hai (play/pause
                // button ke spinner-disabled look jaisa hi consistent).
                activeTrackColor:
                    widget.enabled ? widget.activeColor : Colors.white24,
                // Buffered bar upar se dikhta rahe — is track ka apna
                // "inactive" hissa transparent rakha, warna buffered bar
                // ko dhak dega.
                inactiveTrackColor:
                    bufferedFraction > 0 ? Colors.transparent : Colors.white24,
                thumbColor: widget.enabled ? widget.activeColor : Colors.white38,
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: displayMs,
                max: hasDuration ? maxMs.toDouble() : 1.0,
                onChangeStart: interactive
                    ? (value) => setState(() {
                          _dragging = true;
                          _dragMs = value;
                        })
                    : null,
                // Drag ke dauraan SIRF local UI update — koi network seek
                // nahi (yehi asli fix hai).
                onChanged: interactive
                    ? (value) => setState(() => _dragMs = value)
                    : null,
                // Asli seek SIRF yahan, finger uthane par, ek hi baar.
                onChangeEnd: interactive
                    ? (value) {
                        setState(() => _dragging = false);
                        widget.onSeek(Duration(milliseconds: value.round()));
                      }
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
              Text(_format(_dragging
                  ? Duration(milliseconds: _dragMs.round())
                  : widget.position), style: TextStyle(color: kTextDim, fontSize: 12)),
              Text(_format(widget.total), style: TextStyle(color: kTextDim, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

