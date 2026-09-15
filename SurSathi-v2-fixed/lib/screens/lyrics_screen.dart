// lib/screens/lyrics_screen.dart
// Lyrics viewer — local cache (SharedPreferences) se lyrics dikhata hai,
// warna dummy placeholder.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';

class LyricsScreen extends StatefulWidget {
  final Song song;

  const LyricsScreen({super.key, required this.song});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  static const _kPlaceholder = 'Lyrics abhi available nahi hai. Jaldi aayega.';

  bool _loading = true;
  bool _fullScreen = false;
  String? _lyrics;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  Future<void> _loadLyrics() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('lyrics_${widget.song.id}');
    if (!mounted) return;
    setState(() {
      _lyrics = cached;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final hasLyrics = !_loading && _lyrics != null && _lyrics!.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: kBg,
      appBar: _fullScreen
          ? null
          : AppBar(
              backgroundColor: kBg,
              elevation: 0,
              title: Text('Lyrics', style: AppText.displayM(color: kGreen)),
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen, color: kTextDim),
                  onPressed: () => setState(() => _fullScreen = true),
                ),
              ],
            ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                if (!_fullScreen) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: song.thumb,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) => Container(
                        width: 120,
                        height: 120,
                        color: kSurface,
                        child: const Icon(Icons.music_note, color: kTextDim),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    song.title,
                    style: AppText.displayS(),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    style: AppText.bodyS(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 30),
                ] else
                  const SizedBox(height: 50),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(color: kGreen),
                        )
                      : hasLyrics
                          ? SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                              child: Text(
                                _lyrics!,
                                style: AppText.bodyL(color: kText).copyWith(
                                  fontSize: _fullScreen ? 18 : 16,
                                  height: 1.8,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'Lyrics not available',
                                    style: AppText.bodyL(color: kTextDim),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _kPlaceholder,
                                    style: AppText.bodyM(),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 20),
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: kGreen),
                                    ),
                                    onPressed: () {
                                      // URL launcher abhi implement nahi hai —
                                      // filhaal sirf ek info dikha dete hain.
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Google search jaldi available hoga',
                                          ),
                                        ),
                                      );
                                    },
                                    child: Text(
                                      'Search on Google',
                                      style: AppText.button(color: kGreen),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                ),
              ],
            ),
            if (_fullScreen)
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.fullscreen_exit, color: kTextDim),
                  onPressed: () => setState(() => _fullScreen = false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
