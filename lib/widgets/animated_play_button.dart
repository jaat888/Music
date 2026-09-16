// lib/widgets/animated_play_button.dart
// Full player ka main play/pause button — tap bounce + playing pulse animation.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';

class AnimatedPlayButton extends StatefulWidget {
  final bool isPlaying;
  final VoidCallback onTap;
  final double size;

  const AnimatedPlayButton({
    super.key,
    required this.isPlaying,
    required this.onTap,
    this.size = 70,
  });

  @override
  State<AnimatedPlayButton> createState() => _AnimatedPlayButtonState();
}

class _AnimatedPlayButtonState extends State<AnimatedPlayButton>
    with TickerProviderStateMixin {
  late final AnimationController _tapController;
  late final Animation<double> _tapScale;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    // Tap pe chhota bounce: 1.0 -> 0.9 -> 1.0
    //
    // BUG FIX (2026-09-16, v15): pehle Curves.easeOutBack seedha TweenSequence
    // ke PARENT CurvedAnimation pe laga hua tha. easeOutBack apni nature se
    // 1.0 se aage overshoot karta hai (jaise 1.08) — TweenSequence.evaluate()
    // ko t hamesha 0.0-1.0 ke beech chahiye hota hai, warna ye crash karta
    // hai: "Bad state: TweenSequence.evaluate() could not find an interval".
    // Har tap pe ye crash aata tha aur button ka build() baar-baar fail hone
    // lagta tha — isi wajah se play/pause kaam karna band ho jaata tha.
    // Fix: outer driver ab plain linear _tapController hai (jo hamesha
    // 0.0-1.0 ke beech rehta hai), aur overshoot wala easeOutBack curve sirf
    // dusre TweenSequenceItem ke apne CurveTween me chain kiya hai — bounce
    // wahi dikhta hai, lekin ab overall t kabhi range se bahar nahi jaata.
    _tapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _tapScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.9)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.9, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 1,
      ),
    ]).animate(_tapController);

    // Playing hote waqt subtle continuous pulse
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseScale = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isPlaying) _pulseController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AnimatedPlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      widget.isPlaying
          ? _pulseController.repeat(reverse: true)
          : _pulseController.stop();
    }
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    _tapController.forward(from: 0);
    widget.onTap();
  }

  @override
  void dispose() {
    _tapController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: Listenable.merge([_tapController, _pulseController]),
        builder: (context, child) {
          // Tap-bounce aur playing-pulse dono scales combine ho jate hain
          final scale = _tapScale.value * _pulseScale.value;
          return Transform.scale(scale: scale, child: child);
        },
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [kGreen, kBlue],
            ),
            boxShadow: [
              BoxShadow(
                color: kGreen.withValues(alpha: 0.5),
                blurRadius: 20,
              ),
            ],
          ),
          child: Icon(
            widget.isPlaying ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
            size: widget.size * 0.57,
          ),
        ),
      ),
    );
  }
}
