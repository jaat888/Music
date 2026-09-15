// lib/screens/stats_screen.dart
// Listening stats — dummy/placeholder data (koi real tracking engine nahi
// hai abhi, jaisa spec ne khud bola: "actual tracking baad me").

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/cache_db.dart';
import '../db/liked_db.dart';
import '../models/song.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/section_header.dart';

const List<String> _kRanges = ['Week', 'Month', 'Year', 'All'];
const List<String> _kDayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// Range chip sirf demo ke liye totals ko scale karta hai — koi real
// time-window filtering nahi hai (per-play timestamp store hi nahi hote).
const Map<String, double> _kRangeMultiplier = {
  'Week': 0.25,
  'Month': 1,
  'Year': 11,
  'All': 30,
};

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  bool _loading = true;
  String _range = 'Month';

  int _playedBase = 0;
  int _listenedSecondsBase = 0;
  int _streak = 0;
  String _topArtist = '-';
  List<Song> _topSongs = [];
  List<MapEntry<String, int>> _topArtists = [];
  List<double> _weekBars = List.filled(7, 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    final played = prefs.getInt('played_songs') ?? 0;
    final seconds = prefs.getInt('listened_seconds') ?? 0;
    final streak = prefs.getInt('streak') ?? 0;
    final topArtistsPref = prefs.getStringList('top_artists') ?? [];
    final weekRaw = prefs.getStringList('daily_listened_seconds');

    // Real songs jo app me already maujood hain (liked + cached) inko pool
    // banate hain — per-song play-count track karne wala koi engine nahi
    // hai abhi, isliye rank dikhane ke liye ek stable dummy count use kiya
    // gaya hai (NOTES.md dekho).
    final liked = await LikedDB.instance.getAll();
    final cached = await CacheDB.instance.getAll();
    final pool = <String, Song>{};
    for (final s in liked) {
      pool[s.id] = s;
    }
    for (final c in cached) {
      final id = c['id'] as String;
      pool.putIfAbsent(
        id,
        () => Song(
          id: id,
          title: c['title'] as String? ?? 'Unknown',
          artist: c['artist'] as String? ?? 'Unknown Artist',
          thumb: c['thumb'] as String? ?? '',
          duration: (c['duration'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    final allSongs = pool.values.toList()
      ..sort((a, b) => _dummyCount(b.id).compareTo(_dummyCount(a.id)));
    final topSongs = allSongs.take(5).toList();

    final artistCounts = <String, int>{};
    for (final s in allSongs) {
      artistCounts[s.artist] = (artistCounts[s.artist] ?? 0) + _dummyCount(s.id);
    }
    final topArtistsList = artistCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final weekBars = (weekRaw != null && weekRaw.length == 7)
        ? weekRaw.map((e) => double.tryParse(e) ?? 0).toList()
        : List<double>.filled(7, 0);

    if (!mounted) return;
    setState(() {
      _playedBase = played;
      _listenedSecondsBase = seconds;
      _streak = streak;
      _topArtist = topArtistsPref.isNotEmpty
          ? topArtistsPref.first
          : (topArtistsList.isNotEmpty ? topArtistsList.first.key : '-');
      _topSongs = topSongs;
      _topArtists = topArtistsList.take(5).toList();
      _weekBars = weekBars;
      _loading = false;
    });
  }

  // Song id se stable dummy play-count (1-50) — sirf UI demo ke liye
  int _dummyCount(String id) => (id.hashCode.abs() % 50) + 1;

  double get _multiplier => _kRangeMultiplier[_range] ?? 1;

  int get _totalPlayed => (_playedBase * _multiplier).round();

  int get _hoursListened => ((_listenedSecondsBase * _multiplier) / 3600).round();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          'Statistics',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kGreen))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _buildRangeChips(),
                  const SizedBox(height: 16),
                  _buildStatsGrid(),
                  const SizedBox(height: 8),
                  SectionHeader(title: 'Top Songs'),
                  if (_topSongs.isEmpty)
                    _emptyRow('Abhi koi song nahi — liked/cached songs yahan dikhengi')
                  else
                    ...List.generate(_topSongs.length, (i) {
                      final s = _topSongs[i];
                      return _RankedTile(
                        rank: i + 1,
                        thumb: s.thumb,
                        title: s.title,
                        subtitle: '${_dummyCount(s.id)} plays',
                      );
                    }),
                  const SizedBox(height: 8),
                  SectionHeader(title: 'Top Artists'),
                  if (_topArtists.isEmpty)
                    _emptyRow('Abhi koi artist data nahi')
                  else
                    ...List.generate(_topArtists.length, (i) {
                      final entry = _topArtists[i];
                      return _RankedTile(
                        rank: i + 1,
                        title: entry.key,
                        subtitle: '${entry.value} plays',
                      );
                    }),
                  const SizedBox(height: 8),
                  SectionHeader(title: 'Last 7 Days'),
                  _buildWeekChart(),
                  const SizedBox(height: 40),
                ],
              ),
      ),
    );
  }

  Widget _emptyRow(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text, style: AppText.bodyS()),
      );

  Widget _buildRangeChips() {
    return Row(
      children: _kRanges.map((r) {
        final selected = r == _range;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(r),
            selected: selected,
            onSelected: (_) => setState(() => _range = r),
            backgroundColor: kSurface,
            selectedColor: kGreen,
            labelStyle: AppText.bodyS(color: selected ? kBg : kText).copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildStatsGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        _CountUpCard(label: 'Total Songs Played', value: _totalPlayed),
        _CountUpCard(label: 'Hours Listened', value: _hoursListened),
        _StatCard(label: 'Top Artist', text: _topArtist),
        _CountUpCard(label: 'Current Streak (days)', value: _streak),
      ],
    );
  }

  Widget _buildWeekChart() {
    return Container(
      height: 160,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _WeekBarPainter(values: _weekBars),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _kDayLabels
                .map((d) => Text(d, style: AppText.bodyS().copyWith(fontSize: 10)))
                .toList(),
          ),
        ],
      ),
    );
  }
}

// ---------------- Ranked tile (Top Songs / Top Artists) ----------------

class _RankedTile extends StatelessWidget {
  final int rank;
  final String? thumb;
  final String title;
  final String subtitle;

  const _RankedTile({
    required this.rank,
    required this.title,
    required this.subtitle,
    this.thumb,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              style: AppText.bodyL(color: kTextDim).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (thumb != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: thumb!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: thumb!,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(width: 40, height: 40, color: kSurface),
                      errorWidget: (_, __, ___) => Container(
                        width: 40,
                        height: 40,
                        color: kSurface,
                        child: const Icon(Icons.music_note, color: kTextDim, size: 18),
                      ),
                    )
                  : Container(
                      width: 40,
                      height: 40,
                      color: kSurface,
                      child: const Icon(Icons.music_note, color: kTextDim, size: 18),
                    ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.bodyM(color: kText).copyWith(fontSize: 14),
            ),
          ),
          Text(subtitle, style: AppText.bodyS().copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

// ---------------- Stat cards ----------------

class _StatCard extends StatelessWidget {
  final String label;
  final String text;

  const _StatCard({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.displayS(color: kGreen).copyWith(fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(label, style: AppText.bodyS().copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

// Number "count-up" hoke render hota hai — spec ne bola tha "dummy count-up
// animation for demo"
class _CountUpCard extends StatelessWidget {
  final String label;
  final int value;

  const _CountUpCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: value),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text(
              '$v',
              style: AppText.displayS(color: kGreen).copyWith(fontSize: 20),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: AppText.bodyS().copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

// ---------------- Last-7-days bar chart ----------------

class _WeekBarPainter extends CustomPainter {
  final List<double> values;

  _WeekBarPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final safeMax = maxV <= 0 ? 1.0 : maxV;

    final gap = size.width / (values.length * 2);
    final barWidth = gap;
    final paint = Paint()..color = kGreen;

    for (var i = 0; i < values.length; i++) {
      final h = (values[i] / safeMax) * size.height;
      final x = gap * (2 * i + 0.5);
      final rect = Rect.fromLTWH(
        x,
        size.height - h,
        barWidth,
        h < 3 ? 3 : h, // bilkul flat na dikhe, minimum height rakho
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeekBarPainter oldDelegate) =>
      oldDelegate.values != values;
}
