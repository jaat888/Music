// lib/widgets/section_header.dart
// Home/list screens ke sections ke liye reusable header — title + optional "See all".

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  final EdgeInsets padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.onSeeAll,
    this.padding = const EdgeInsets.symmetric(vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: AppText.displayS(color: kText)),
          // "See all" sirf tab dikhega jab callback diya gaya ho
          if (onSeeAll != null)
            GestureDetector(
              onTap: onSeeAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'See all',
                    style: AppText.bodyM(color: kGreen).copyWith(fontSize: 13),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.arrow_forward_ios, color: kGreen, size: 12),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
