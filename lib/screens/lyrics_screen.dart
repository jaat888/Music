// lib/screens/lyrics_screen.dart
// Lyrics viewer — ab REAL: lrclib.net se time-synced (LRC) lyrics fetch
// karta hai (LyricsService, SharedPreferences me cached), aur agar synced
// data mila to current playback position ke saath LIVE highlight/auto-
// scroll hota hai (audioHandler.player.positionStream). Agar sirf plain
// (untimed) lyrics milein to static text dikhta hai jaisa pehle. Kuch na
// mile to purana "not available" + Google search fallback.

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../services/app_logger.dart';
import '../services/background_service.dart';
import '../services/lyrics_service.dart';

class LyricsScreen extends StatefulWidget {
  final Song song;

  const LyricsScreen({super.key, required this.song});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  bool _loading = true;
  bool _fullScreen = false;
  LyricsResult? _result;

  final ScrollController _scrollController = ScrollController();
  int _lastActiveIndex = -1;
  static const double _lineHeight = 52;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    final song = widget.song;
    final result = await LyricsService.instance.getForSong(
      songId: song.id,
      title: song.title,
      artist: song.artist,
      durationSeconds: song.duration,
    );
    if (!mounted) return;
    // NEW (2026-09-18 — user report: "subtitle ka sab log nahi aata"):
    // ab load ka result (synced / plain / kuch nahi) explicitly log hota
    // hai, taaki agar lyrics-related dikkat ho to log se pata chal sake ki
    // kya mila tha.
    final kind = (result?.synced?.isNotEmpty ?? false)
        ? 'synced (${result!.synced!.length} lines)'
        : ((result?.plain?.trim().isNotEmpty ?? false) ? 'plain-only' : 'none');
    AppLogger.instance.log(
      '[LYRICS] loaded for "${song.title}" (${song.id}) — result: $kind',
    );
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  int _activeIndexFor(Duration position, List<LyricLine> lines) {
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].time <= position) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _maybeAutoScroll(int index, Duration position, List<LyricLine> lines) {
    if (index == _lastActiveIndex) return;
    _lastActiveIndex = index;
    // NEW (2026-09-18 — user report: "subtitle screen pe kab aaya, gaane
    // ke beech mein ya baad mein, exact time ke saath log ho"): har line-
    // change ko uske exact playback position (mm:ss.mmm) ke saath log
    // karte hain — chahe scroll na bhi ho (index -1 ya no clients).
    if (index >= 0 && index < lines.length) {
      final pos = position;
      final mm = pos.inMinutes.remainder(60).toString().padLeft(2, '0');
      final ss = pos.inSeconds.remainder(60).toString().padLeft(2, '0');
      final ms = pos.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
      AppLogger.instance.log(
        '[LYRICS] line #$index active at $mm:$ss.$ms — "${lines[index].text}"',
      );
    }
    if (!_scrollController.hasClients) return;
    final target = (index * _lineHeight) -
        (_scrollController.position.viewportDimension / 2) +
        (_lineHeight / 2);
    _scrollController.animateTo(
      target.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  Future<void> _searchOnGoogle() async {
    final q = Uri.encodeComponent('${widget.song.title} ${widget.song.artist} lyrics');
    final uri = Uri.parse('https://www.google.com/search?q=$q');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _buildSyncedLyrics(List<LyricLine> lines) {
    return StreamBuilder<Duration>(
      stream: audioHandler.player.positionStream,
      initialData: Duration.zero,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final activeIndex = _activeIndexFor(pos, lines);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _maybeAutoScroll(activeIndex, pos, lines));
        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.symmetric(
            vertical: MediaQuery.of(context).size.height / 3,
            horizontal: 28,
          ),
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final isActive = i == activeIndex;
            // BUG FIX (2026-09-18 — user report: "bahut badi subtitle hain,
            // unko bhi thik karo"): pehle yahan ek FIXED height (52) wale
            // Container me plain Text tha, bina maxLines/overflow ke — ek
            // genuinely lambi lyric line yahan overflow karke agli/pichli
            // line ke upar clip/overlap ho jaati thi. FittedBox(scaleDown)
            // + maxLines:2 guarantee karta hai ki chahe line kitni bhi badi
            // ho, wo hamesha apne fixed box ke andar hi fit hoga (font
            // thoda chhota ho jayega, kabhi overflow/clip nahi hoga) — scroll
            // math (_lineHeight based) bhi isi wajah se bilkul waisa hi
            // rehta hai, kuch aur nahi badla.
            return Container(
              height: _lineHeight,
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  lines[i].text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyL(
                    color: isActive ? kGreen : kTextDim,
                  ).copyWith(
                    fontSize: isActive ? 20 : 16,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlainLyrics(String text) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Text(
        text,
        style: AppText.bodyL(color: kText).copyWith(
          fontSize: _fullScreen ? 18 : 16,
          height: 1.8,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildUnavailable() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Lyrics not available', style: AppText.bodyL(color: kTextDim)),
          const SizedBox(height: 10),
          Text(
            'Is gaane ke lyrics nahi mile.',
            style: AppText.bodyM(),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: kGreen)),
            onPressed: _searchOnGoogle,
            child: Text('Search on Google', style: AppText.button(color: kGreen)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final result = _result;

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
                  icon: Icon(Icons.fullscreen, color: kTextDim),
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
                        child: Icon(Icons.music_note, color: kTextDim),
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
                  Text(song.artist, style: AppText.bodyS(), textAlign: TextAlign.center),
                  const SizedBox(height: 30),
                ] else
                  const SizedBox(height: 50),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator(color: kGreen))
                      : (result?.hasSynced ?? false)
                          ? _buildSyncedLyrics(result!.synced!)
                          : (result?.plain?.trim().isNotEmpty ?? false)
                              ? _buildPlainLyrics(result!.plain!)
                              : _buildUnavailable(),
                ),
              ],
            ),
            if (_fullScreen)
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: Icon(Icons.fullscreen_exit, color: kTextDim),
                  onPressed: () => setState(() => _fullScreen = false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
