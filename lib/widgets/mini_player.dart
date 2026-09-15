// lib/widgets/mini_player.dart
// Bottom mini player bar — home/library screens ke neeche persist rehta hai.

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../services/background_service.dart';
import 'equalizer_bars.dart';

class MiniPlayer extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback onLike;
  final bool isLiked;

  const MiniPlayer({
    super.key,
    required this.onTap,
    required this.onLike,
    required this.isLiked,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, mediaSnap) {
        final item = mediaSnap.data;
        // Koi song load nahi hai to mini player dikhana hi nahi
        if (item == null) return const SizedBox.shrink();

        return GestureDetector(
          onTap: onTap,
          onVerticalDragEnd: (details) {
            // Fast upar-swipe pe bhi full player khol do
            if ((details.primaryVelocity ?? 0) < -200) onTap();
          },
          child: Container(
            height: 70,
            width: double.infinity,
            color: kGreen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  // ---------- Thumbnail ----------
                  Hero(
                    tag: 'thumb-${item.id}',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: item.artUri != null
                          ? CachedNetworkImage(
                              imageUrl: item.artUri.toString(),
                              width: 50,
                              height: 50,
                              fit: BoxFit.cover,
                              errorWidget: (context, url, error) => Container(
                                width: 50,
                                height: 50,
                                color: Colors.black26,
                                child: const Icon(Icons.music_note, color: Colors.black54),
                              ),
                            )
                          : Container(
                              width: 50,
                              height: 50,
                              color: Colors.black26,
                              child: const Icon(Icons.music_note, color: Colors.black54),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // ---------- Title + artist (BLACK — green bg pe white nahi dikhega) ----------
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.black54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  // ---------- Equalizer + heart + play/pause ----------
                  StreamBuilder<PlayerState>(
                    stream: audioHandler.player.playerStateStream,
                    builder: (context, stateSnap) {
                      final playing = stateSnap.data?.playing ?? false;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (playing) ...[
                            const EqualizerBars(color: Colors.black, size: 22, isPlaying: true),
                            const SizedBox(width: 6),
                          ],
                          IconButton(
                            icon: Icon(
                              isLiked ? Icons.favorite : Icons.favorite_border,
                              color: Colors.black,
                            ),
                            iconSize: 26,
                            onPressed: onLike,
                          ),
                          IconButton(
                            icon: Icon(
                              playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                              color: Colors.black,
                            ),
                            iconSize: 42,
                            onPressed: () {
                              playing ? audioHandler.pause() : audioHandler.play();
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
