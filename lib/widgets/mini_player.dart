// lib/widgets/mini_player.dart
// Bottom mini player bar — home/library screens ke neeche persist rehta hai.

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../db/download_db.dart';
import '../services/background_service.dart';
import '../services/queue_service.dart';
import '../services/youtube_service.dart';
import 'equalizer_bars.dart';

// NEW: mini player ab currently-streaming gaana seedhe yahin se download
// kar sakta hai (koi list/screen me jaake dobara dhundhna nahi padta), aur
// isi gaane ke artist ke aas-paas ka "radio" bhi shuru kar sakta hai. Isi
// wajah se ab StatefulWidget hai (download/radio ke "in progress" spinner
// dikhane ke liye local state chahiye).
class MiniPlayer extends StatefulWidget {
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
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  bool _downloading = false;
  bool _startingRadio = false;

  Future<void> _handleDownload(MediaItem item) async {
    if (_downloading) return;
    final already = await DownloadDB.instance.exists(item.id);
    if (!mounted) return;
    if (already) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ye gaana pehle se downloaded hai')),
      );
      return;
    }
    setState(() => _downloading = true);
    final path = await YoutubeService.instance.download(
      item.id,
      item.title,
      author: item.artist,
    );
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path != null ? '${item.title} download ho gaya' : 'Download fail ho gaya',
        ),
      ),
    );
  }

  Future<void> _handleRadio(MediaItem item) async {
    if (_startingRadio) return;
    setState(() => _startingRadio = true);
    final added = await YoutubeService.instance.getRadioQueue(
      item.id,
      item.title,
      item.artist ?? '',
    );
    if (!mounted) return;
    setState(() => _startingRadio = false);
    if (added.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Radio ke liye gaane nahi mile')),
      );
      return;
    }
    QueueService.instance.addAll(added);
    QueueService.instance.enableRadioMode(
      () => YoutubeService.instance.loadMoreRadioQueue(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Radio shuru — ${added.length} gaane queue me add ho gaye')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, mediaSnap) {
        final item = mediaSnap.data;
        // Koi song load nahi hai to mini player dikhana hi nahi
        if (item == null) return const SizedBox.shrink();

        return GestureDetector(
          onTap: widget.onTap,
          onVerticalDragEnd: (details) {
            // Fast upar-swipe pe bhi full player khol do
            if ((details.primaryVelocity ?? 0) < -200) widget.onTap();
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
                  // BUG FIX: pehle sirf playerStateStream.playing dekha
                  // jaata tha, jo URL resolve hone tak "false" hi rehta hai
                  // — is beech tap karne pe play icon hi dikhta rehta tha,
                  // koi indication nahi ki kuch load ho raha hai (isi wajah
                  // se "click karo to kuch hota hi nahi" feel aata tha). Ab
                  // audioHandler.playbackState (jisme loading/buffering
                  // state background_service se turant broadcast hoti hai)
                  // bhi dekhte hain aur spinner dikhate hain jab tak stream
                  // URL resolve na ho jaaye.
                  StreamBuilder<PlaybackState>(
                    stream: audioHandler.playbackState,
                    builder: (context, pbSnap) {
                      final processingState = pbSnap.data?.processingState;
                      // NEW (2026-09-16): pehle error state me bhi play
                      // icon hi dikhta rehta tha — tap karne pe kuch nahi
                      // hota tha (player.play() ek bina-URL/khaali source
                      // pe kuch nahi karta), user ko lagta tha button
                      // kaam nahi kar raha. Ab error pe seedha Retry
                      // (refresh) icon dikhta hai jo currentSong ko
                      // dobara resolve karne ki koshish karta hai.
                      final isError =
                          processingState == AudioProcessingState.error;

                      return StreamBuilder<PlayerState>(
                        stream: audioHandler.player.playerStateStream,
                        builder: (context, stateSnap) {
                          final playing = stateSnap.data?.playing ?? false;
                          // BUG FIX (2026-09-16, v8): "play/pause 1 sec
                          // glitch". Pehle isLoading sirf processingState
                          // (loading/buffering) pe based tha. Jab tap karke
                          // resume karte hain, just_audio/ExoPlayer network
                          // stream ko thodi der ke liye phir se "buffering"
                          // report karta hai — chahe audio turant baj raha
                          // ho (playerStateStream se playing: true already
                          // aa chuka). Ye spinner ko pause icon ke upar
                          // ~1 sec ke liye overlay kar deta tha, isliye
                          // button "glitch/flicker" karta lagta tha. Ab
                          // agar player already playing hai to buffering
                          // blip ignore karte hain — spinner sirf tab
                          // dikhega jab gaana abhi tak bilkul bhi bajna
                          // shuru nahi hua (loading) ya buffering ho raha
                          // hai AUR abhi playing nahi hai.
                          final isLoading = processingState ==
                                  AudioProcessingState.loading ||
                              (processingState ==
                                      AudioProcessingState.buffering &&
                                  !playing);
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (playing) ...[
                                const EqualizerBars(color: Colors.black, size: 20, isPlaying: true),
                                const SizedBox(width: 4),
                              ],
                              // NEW — jo abhi stream ho raha hai wahi seedha
                              // yahin se download ho sake, bina kisi list
                              // me jaake dhundhe.
                              FutureBuilder<bool>(
                                // FIX: mini player me bhi download icon ab
                                // "already downloaded" state dikhata hai.
                                future: DownloadDB.instance.exists(item.id),
                                builder: (context, dlSnap) {
                                  final isDownloaded = dlSnap.data ?? false;
                                  return IconButton(
                                    icon: _downloading
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.black,
                                            ),
                                          )
                                        : Icon(
                                            isDownloaded
                                                ? Icons.download_done_rounded
                                                : Icons.download_rounded,
                                            color: isDownloaded
                                                ? kGreen
                                                : Colors.black,
                                          ),
                                    iconSize: 20,
                                    tooltip:
                                        isDownloaded ? 'Downloaded' : 'Download',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    onPressed: _downloading
                                        ? null
                                        : () => _handleDownload(item),
                                  );
                                },
                              ),
                              // NEW — isi gaane/artist jaisa "radio" queue
                              // me add kar deta hai (current gaana disturb
                              // nahi hota, baad me ye gaane bajenge).
                              Builder(builder: (context) {
                                // FIX: radio "on" hone par icon green.
                                final radioOn =
                                    QueueService.instance.radioMode;
                                return IconButton(
                                  icon: _startingRadio
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.black,
                                          ),
                                        )
                                      : Icon(
                                          Icons.radio_rounded,
                                          color: radioOn ? kGreen : Colors.black,
                                        ),
                                  iconSize: 20,
                                  tooltip:
                                      radioOn ? 'Radio band karo' : 'Radio shuru karo',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  onPressed: _startingRadio
                                      ? null
                                      : () => radioOn
                                          ? QueueService.instance
                                              .disableRadioMode()
                                          : _handleRadio(item),
                                );
                              }),
                              IconButton(
                                icon: Icon(
                                  widget.isLiked ? Icons.favorite : Icons.favorite_border,
                                  color: Colors.black,
                                ),
                                iconSize: 24,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                onPressed: widget.onLike,
                              ),
                              SizedBox(
                                width: 42,
                                height: 42,
                                child: isLoading
                                    ? const Padding(
                                        padding: EdgeInsets.all(9),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.black,
                                        ),
                                      )
                                    : isError
                                        ? IconButton(
                                            padding: EdgeInsets.zero,
                                            tooltip: 'Retry',
                                            icon: const Icon(
                                              Icons.refresh_rounded,
                                              color: Colors.black,
                                            ),
                                            iconSize: 34,
                                            onPressed: () =>
                                                audioHandler.retryCurrent(),
                                          )
                                        : IconButton(
                                            padding: EdgeInsets.zero,
                                            icon: Icon(
                                              playing
                                                  ? Icons.pause_circle_filled
                                                  : Icons.play_circle_filled,
                                              color: Colors.black,
                                            ),
                                            iconSize: 42,
                                            onPressed: () {
                                              playing
                                                  ? audioHandler.pause()
                                                  : audioHandler.play();
                                            },
                                          ),
                              ),
                            ],
                          );
                        },
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
