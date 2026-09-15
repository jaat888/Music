// lib/widgets/cache_indicator.dart
// Chhota dot jo dikhata hai ki song cache/download ho chuka hai.

import 'package:flutter/material.dart';

import '../theme/colors.dart';

class CacheIndicator extends StatelessWidget {
  final bool isCached;
  final double size;

  const CacheIndicator({
    super.key,
    required this.isCached,
    this.size = 8,
  });

  @override
  Widget build(BuildContext context) {
    if (!isCached) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: 1.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: kGreen,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
