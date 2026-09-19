// lib/screens/queue_screen.dart
// Queue ka poora view — "Now Playing" (fixed) + "Up Next" (drag-reorder + swipe-delete).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../services/queue_service.dart';

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  // Seconds ko "m:ss" format me convert karta hai
  String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final minutes = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  void _confirmClear(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Queue clear karein?', style: AppText.displayS()),
        content: Text(
          'Poori queue khaali ho jayegi. Ye undo nahi ho sakta.',
          style: AppText.bodyM(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () {
              context.read<QueueService>().clear();
              Navigator.pop(ctx);
            },
            child: Text('Clear', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
  }

  Widget _thumb(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 50,
        height: 50,
        fit: BoxFit.cover,
        placeholder: (context, url) =>
            Container(width: 50, height: 50, color: kSurface),
        errorWidget: (context, url, error) => Container(
          width: 50,
          height: 50,
          color: kSurface,
          child: Icon(Icons.music_note, color: kTextDim),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final queueService = context.watch<QueueService>();
    final currentSong = queueService.currentSong;
    final upcoming = queueService.upcoming;
    // v106: `upcoming` ab PLAY ORDER mein hai (shuffle ON ho to physical
    // queue order se alag) — isliye har item ka full-queue index alag se
    // aata hai, `currentIndex + 1 + i` nahi.
    final upcomingIndices = queueService.upcomingIndices;
    final fullQueue = queueService.queue;

    final totalSeconds = fullQueue.fold<int>(0, (sum, s) => sum + s.duration);
    final totalMinutes = (totalSeconds / 60).round();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Queue', style: AppText.displayM(color: kGreen)),
        actions: [
          TextButton(
            onPressed: fullQueue.isEmpty ? null : () => _confirmClear(context),
            child: Text(
              'Clear',
              style: AppText.button(
                color: fullQueue.isEmpty ? kTextDim : kRed,
              ),
            ),
          ),
        ],
      ),
      body: fullQueue.isEmpty
          ? Center(
              child: Text(
                'Queue khaali hai',
                style: AppText.bodyL(color: kTextDim),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${fullQueue.length} songs · $totalMinutes min',
                      style: AppText.bodyS(),
                    ),
                  ),
                ),
                if (currentSong != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Now Playing', style: AppText.label()),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: kBgElev,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kGreen, width: 1.5),
                      ),
                      child: Row(
                        children: [
                          _thumb(currentSong.thumb),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  currentSong.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.bodyM(color: kText)
                                      .copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  currentSong.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.bodyS(),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.graphic_eq, color: kGreen, size: 20),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Up Next', style: AppText.label()),
                  ),
                ),
                Expanded(
                  child: upcoming.isEmpty
                      ? Center(
                          child: Text(
                            'Aage koi song nahi hai',
                            style: AppText.bodyM(),
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.only(top: 6, bottom: 24),
                          itemCount: upcoming.length,
                          onReorder: (oldLocalIndex, newLocalIndex) {
                            context.read<QueueService>().reorderUpcoming(
                                  oldLocalIndex,
                                  newLocalIndex,
                                );
                          },
                          itemBuilder: (context, i) {
                            final song = upcoming[i];
                            final actualIndex = upcomingIndices[i];

                            return Dismissible(
                              key: ValueKey('${song.id}_$actualIndex'),
                              background: Container(
                                color: kRed,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 24),
                                child: const Icon(Icons.delete,
                                    color: Colors.white),
                              ),
                              onDismissed: (_) => context
                                  .read<QueueService>()
                                  .removeAt(actualIndex),
                              child: ListTile(
                                onTap: () {
                                  context
                                      .read<QueueService>()
                                      .jumpTo(actualIndex);
                                  Navigator.pop(context);
                                },
                                leading: ReorderableDragStartListener(
                                  index: i,
                                  child:  Icon(
                                    Icons.drag_handle,
                                    color: kTextDim,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    _thumb(song.thumb),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            song.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppText.bodyM(color: kText),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${song.artist} · ${_formatDuration(song.duration)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppText.bodyS(),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: IconButton(
                                  icon:  Icon(Icons.close,
                                      color: kTextDim, size: 20),
                                  onPressed: () => context
                                      .read<QueueService>()
                                      .removeAt(actualIndex),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
