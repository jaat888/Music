// lib/widgets/rotating_vinyl.dart
// Full player ka rotating album art — vinyl record jaisa ghoomta hai.

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';

class RotatingVinyl extends StatefulWidget {
  final String imageUrl;
  final double size;
  final bool isPlaying;

  const RotatingVinyl({
    super.key,
    required this.imageUrl,
    this.size = 260,
    required this.isPlaying,
  });

  @override
  State<RotatingVinyl> createState() => _RotatingVinylState();
}

class _RotatingVinylState extends State<RotatingVinyl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant RotatingVinyl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      // Pause pe ghoomna ruk jaaye, play pe wahi angle se continue ho
      widget.isPlaying ? _controller.repeat() : _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(colors: [kGreen, kBlue]),
          boxShadow: [
            BoxShadow(
              color: kGreen.withValues(alpha: 0.4),
              blurRadius: 40,
            ),
          ],
        ),
        padding: const EdgeInsets.all(20),
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: widget.imageUrl,
            fit: BoxFit.cover,
            errorWidget: (context, url, error) =>
                const Icon(Icons.music_note, color: Colors.white, size: 100),
          ),
        ),
      ),
    );
  }
}
