// lib/screens/stats_screen.dart
// Part 6 (Stats/Streak gamification) — pehle ye poori screen dummy/
// placeholder data pe thi (SharedPreferences counters + id.hashCode-based
// fake per-song play-count, koi asli tracking nahi). Ab sab kuch
// PlayHistoryDB (Part 3 me bani asli play_history table) se real hai:
// total plays, listened seconds (duration-sum approximation), streak,
// top artists, last-7-days chart — sab actual play records se compute
// hote hain. Range chips (Week/Month/Year/All) ab asli played_at cutoff
// se filter karte hain, koi multiplier-hack nahi.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../db/play_history_db.dart';
import '../models/song.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/section_header.dart';

const List<String> _kRanges = ['Week', 'Month', 'Year', 'All'];

class _Badge {
  final String emoji;
  final String label;
  final bool Function(int totalPlays, int streak) unlockedWhen;
  const _Badge(this.emoji, this.label, this.unlockedWhen);
}

// Simple gamification milestones — total plays aur streak dono existing
// (Part 3) play_history data se aate hain, koi naya tracking system nahi
// chahiye.
const List<_Badge> _kBadges = [
  _Badge('🔥', '7-Day Streak', _streak7),
  _Badge('⚡', '30-Day Streak', _streak30),
  _Badge('💯', '100 Songs', _plays100),
  _Badge('🎧', '500 Songs', _plays500),
];
bool _streak7(int p, int s) => s >= 7;
bool _streak30(int p, int s) => s >= 30;
bool _plays100(int p, int s) => p >= 100;
bool _plays500(int p, int s) => p >= 500;

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  bool _loading = true;
  String _range = 'Month';

  int _totalPlayed = 0;
  int _listenedSeconds = 0;
  int _streak = 0;
  List<MapEntry<Song, int>> _topSongs = [];
  List<MapEntry<String, int>> _topArtists = [];
  List<MapEntry<DateTime, int>> _last7Days = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  int? get _sinceMillis {
    final now = DateTime.now();
    switch (_range) {
      case 'Week':
        return now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
      case 'Month':
        return now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
      case 'Year':
        return now.subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      default: // All
        return null;
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final since = _sinceMillis;
    final db = PlayHistoryDB.instance;

    final results = await Future.wait([
      db.totalPlays(sinceMillis: since),
      db.totalListenedSeconds(sinceMillis: since),
      db.currentStreakDays(),
      db.getMostPlayed(limit: 5),
      db.getTopArtists(limit: 5, sinceMillis: since),
      db.last7DaysCounts(),
    ]);

    if (!mounted) return;
    setState(() {
      _totalPlayed = results[0] as int;
      _listenedSeconds = results[1] as int;
      _streak = results[2] as int;
      _topSongs = results[3] as List<MapEntry<Song, int>>;
      _topArtists = results[4] as List<MapEntry<String, int>>;
      _last7Days = results[5] as List<MapEntry<DateTime, int>>;
      _loading = false;
    });
  }

  int get _hoursListened => (_listenedSeconds / 3600).round();

  String get _topArtist => _topArtists.isNotEmpty ? _topArtists.first.key : '-';

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
                  SectionHeader(title: 'Badges'),
                  _buildBadges(),
                  const SizedBox(height: 8),
                  SectionHeader(title: 'Top Songs'),
                  if (_topSongs.isEmpty)
                    _emptyRow('Abhi koi play record nahi — kuch gaane suno')
                  else
                    ...List.generate(_topSongs.length, (i) {
                      final entry = _topSongs[i];
                      return _RankedTile(
                        rank: i + 1,
                        thumb: entry.key.thumb,
                        title: entry.key.title,
                        subtitle: '${entry.value} plays',
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
            onSelected: (_) {
              setState(() => _range = r);
              _load();
            },
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

  Widget _buildBadges() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _kBadges.map((b) {
        // Streak-based badges "All time" streak pe hi based hain (range
        // chip in per-badge unlock ko affect nahi karta), plays-based
        // badges range-filtered total pe — jaisa har jagah StatsScreen
        // ke andar consistent rehta hai.
        final unlocked = b.unlockedWhen(_totalPlayed, _streak);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: unlocked ? kGreen.withOpacity(0.15) : kBgElev,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: unlocked ? kGreen : kSurface,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: unlocked ? 1 : 0.3,
                child: Text(b.emoji, style: const TextStyle(fontSize: 18)),
              ),
              const SizedBox(width: 8),
              Text(
                b.label,
                style: AppText.bodyS(color: unlocked ? kText : kTextDim).copyWith(
                  fontWeight: unlocked ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildWeekChart() {
    final values = _last7Days.map((e) => e.value.toDouble()).toList();
    final labels = _last7Days
        .map((e) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][e.key.weekday - 1])
        .toList();
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
              painter: _WeekBarPainter(values: values),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: labels
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
                        child: Icon(Icons.music_note, color: kTextDim, size: 18),
                      ),
                    )
                  : Container(
                      width: 40,
                      height: 40,
                      color: kSurface,
                      child: Icon(Icons.music_note, color: kTextDim, size: 18),
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
