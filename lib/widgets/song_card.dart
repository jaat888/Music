// lib/widgets/song_card.dart
// Song list item — thumbnail, title/artist, aur play/download/like actions.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import 'cache_indicator.dart';

class SongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  final VoidCallback onLike;
  final bool isLiked;
  final bool isCached;
  // Optional — pass karo to download icon ki jagah playlist_add icon dikhta
  // hai (e.g. search_screen.dart). Null rakho to purana download button
  // hamesha jaisa hi rehta hai — baaki saari screens is param ko touch
  // nahi karti, isliye unka behaviour bilkul same rehta hai.
  final VoidCallback? onAddToPlaylist;
  // NEW: song pehle se offline-downloaded hai to download icon ko
  // "on" (green + filled) dikhane ke liye. Default false — jo screens
  // ye pass nahi karti unka behaviour bilkul pehle jaisa hi rehta hai.
  final bool isDownloaded;

  const SongCard({
    super.key,
    required this.song,
    required this.onTap,
    required this.onPlay,
    this.onDownload,
    required this.onLike,
    this.isLiked = false,
    this.isCached = false,
    this.onAddToPlaylist,
    this.isDownloaded = false,
  });

  // Seconds ko "m:ss" format me convert karta hai (e.g. 225 -> "3:45")
  String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final minutes = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBgElev,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              // ---------- Thumbnail ----------
              // BUG FIX (crash on song change): pehle yahan Hero(tag:
              // 'thumb-${song.id}') tha — mini_player.dart aur
              // full_player_screen.dart dono bhi EXACT SAME tag format use
              // karte hain (jaanbujhke — un dono ke beech animation chalti
              // hai). Jab currently-playing gaana isi list me bhi visible
              // rehta (jo ki normal hai — gaana tap karo, wo list se hi
              // play hota hai), to ek hi route ke subtree me 2 heroes same
              // tag ke saath ho jaate the — full player kholte hi seedha
              // "There are multiple heroes that share the same tag within a
              // subtree" crash. List item ko is animation me hissa lene ki
              // zaroorat nahi thi (sirf mini_player <-> full_player wali
              // fly-animation matter karti hai), isliye yahan se Hero hata
              // diya — Stack seedha rakha gaya hai.
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: song.thumb,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: 60,
                        height: 60,
                        color: kSurface,
                      ),
                      errorWidget: (context, url, error) => Container(
                        width: 60,
                        height: 60,
                        color: kSurface,
                        child: Icon(Icons.music_note, color: kTextDim),
                      ),
                    ),
                  ),
                  // Cached hone pe bottom-right fade-in badge dikhao.
                  // BUG FIX (feature wiring): pehle yahan ek hand-rolled
                  // plain green Container tha (koi fade-in animation
                  // nahi) — asli CacheIndicator widget (jo animate karke
                  // render hota hai) kabhi kahin use hi nahi hua tha.
                  // Widget khud hi `isCached == false` par khud ko chhupa
                  // leta hai, isliye bahar wala `if` bhi hata diya.
                  Positioned(
                    bottom: -2,
                    right: -2,
                    child: CacheIndicator(isCached: isCached, size: 10),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              // ---------- Title + artist · duration ----------
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyM(color: kText).copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${song.artist} · ${_formatDuration(song.duration)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyS().copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              // ---------- Actions: play, download, like ----------
              IconButton(
                icon: const Icon(Icons.play_circle_fill, color: kGreen, size: 32),
                onPressed: onPlay,
                splashRadius: 22,
              ),
              if (onAddToPlaylist != null)
                IconButton(
                  icon: Icon(Icons.playlist_add, color: kTextDim, size: 22),
                  onPressed: onAddToPlaylist,
                  splashRadius: 18,
                )
              else if (onDownload != null)
                IconButton(
                  icon: Icon(
                    isDownloaded
                        ? Icons.download_done_rounded
                        : Icons.download_rounded,
                    color: isDownloaded ? kGreen : kTextDim,
                    size: 22,
                  ),
                  tooltip: isDownloaded ? 'Downloaded' : 'Download',
                  onPressed: onDownload,
                  splashRadius: 18,
                ),
              IconButton(
                icon: Icon(
                  isLiked ? Icons.favorite : Icons.favorite_border,
                  color: isLiked ? kRed : kTextDim,
                  size: 22,
                ),
                splashRadius: 18,
                onPressed: () {
                  HapticFeedback.lightImpact();
                  onLike();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
