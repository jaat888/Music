// lib/screens/cache_manager_screen.dart
// Cache storage manage karne ki screen — ring chart, limit slider,
// wifi-only/preload switches, aur cached songs ki list.

import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/cache_db.dart';
import '../services/cache_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

// Slider ke discrete steps — index 4 (-1) matlab Unlimited
const List<int> _kLimitOptions = [
  500 * 1024 * 1024,
  1024 * 1024 * 1024,
  2 * 1024 * 1024 * 1024,
  5 * 1024 * 1024 * 1024,
  -1,
];

// Dart int 64-bit hai (native builds pe), isliye "Unlimited" ke liye ek
// bahut bada practical-safe number use kar rahe hain (koi asli device
// itna cache kabhi nahi bharega)
const int _kUnlimitedBytes = 1 << 60;

// NOTE: CacheService (Batch 4) me sirf limit + wifiOnly hain, "preload next
// song" ka koi field nahi — isliye ye setting yahin locally SharedPreferences
// me save ki gayi hai. Actual preloading logic future me background_service
// me implement karni hogi (NOTES.md dekho).
const String _kPreloadKey = 'cache_preload_next';

class CacheManagerScreen extends StatefulWidget {
  const CacheManagerScreen({super.key});

  @override
  State<CacheManagerScreen> createState() => _CacheManagerScreenState();
}

class _CacheManagerScreenState extends State<CacheManagerScreen> {
  bool _loading = true;
  int _totalBytes = 0;
  int _limitBytes = CacheService.defaultLimitBytes;
  bool _wifiOnly = true;
  bool _preloadNext = true;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final total = await CacheService.instance.currentSize();
    final limit = await CacheService.instance.getLimitBytes();
    final wifiOnly = await CacheService.instance.isWifiOnly();
    final prefs = await SharedPreferences.getInstance();
    final preload = prefs.getBool(_kPreloadKey) ?? true;
    final entries = await CacheDB.instance.getAll();
    if (!mounted) return;
    setState(() {
      _totalBytes = total;
      _limitBytes = limit;
      _wifiOnly = wifiOnly;
      _preloadNext = preload;
      _entries = entries;
      _loading = false;
    });
  }

  // ---------------- Formatting helpers ----------------

  String _formatMB(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  String _limitLabel(int bytes) => bytes < 0 ? 'Unlimited' : _formatMB(bytes);

  int _closestOptionIndex(int bytes) {
    if (bytes < 0 || bytes >= _kUnlimitedBytes) return 4;
    var best = 0;
    var bestDiff = 1 << 62;
    for (var i = 0; i < 4; i++) {
      final diff = (bytes - _kLimitOptions[i]).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  // ---------------- Actions ----------------

  Future<void> _setLimit(int index) async {
    final option = _kLimitOptions[index];
    final bytes = option < 0 ? _kUnlimitedBytes : option;
    await CacheService.instance.setLimit(bytes);
    _load();
  }

  Future<void> _setWifiOnly(bool value) async {
    await CacheService.instance.setWifiOnly(value);
    setState(() => _wifiOnly = value);
  }

  Future<void> _setPreloadNext(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPreloadKey, value);
    setState(() => _preloadNext = value);
  }

  Future<void> _toggleProtected(String id, bool current) async {
    await CacheDB.instance.update(id, protected: current ? 0 : 1);
    _load();
  }

  Future<void> _deleteEntry(Map<String, dynamic> entry) async {
    final filePath = entry['file_path'] as String?;
    if (filePath != null) {
      final file = File(filePath);
      if (await file.exists()) await file.delete();
    }
    await CacheDB.instance.delete(entry['id'] as String);
    _load();
  }

  Future<void> _confirmClearUnprotected() async {
    final confirm = await _confirmDialog(
      title: 'Unprotected cache clear karein?',
      message: 'Liked (protected) songs safe rahenge, baaki sab cache se hat jayega.',
      confirmLabel: 'Clear Unprotected',
    );
    if (confirm != true) return;
    await CacheService.instance.clearAll();
    _load();
  }

  Future<void> _confirmClearAll() async {
    final confirm = await _confirmDialog(
      title: 'Poora cache clear karein?',
      message: 'Ye protected (liked) songs samet SAARA cache hata dega. Ye undo nahi ho sakta.',
      confirmLabel: 'Clear Cache',
    );
    if (confirm != true) return;
    for (final entry in List<Map<String, dynamic>>.of(_entries)) {
      final filePath = entry['file_path'] as String?;
      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) await file.delete();
      }
      await CacheDB.instance.delete(entry['id'] as String);
    }
    _load();
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text(title, style: AppText.displayS()),
        content: Text(message, style: AppText.bodyM()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel, style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          'Cache Manager',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: kGreen,
          backgroundColor: kBgElev,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: kGreen))
              : _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final limitIsUnlimited = _limitBytes < 0 || _limitBytes >= _kUnlimitedBytes;
    final progress = limitIsUnlimited
        ? 0.0
        : (_totalBytes / _limitBytes).clamp(0.0, 1.0);
    final sliderIndex = _closestOptionIndex(_limitBytes).toDouble();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ---------- Storage ring card ----------
        Container(
          padding: const EdgeInsets.symmetric(vertical: 24),
          decoration: BoxDecoration(
            color: kBgElev,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              SizedBox(
                width: 150,
                height: 150,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(150, 150),
                      painter: _RingPainter(
                        progress: limitIsUnlimited ? 0 : progress.toDouble(),
                        color: kGreen,
                        bgColor: kSurface,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${_formatMB(_totalBytes)} / ${_limitLabel(_limitBytes)}',
                          textAlign: TextAlign.center,
                          style: AppText.displayS(color: kText).copyWith(fontSize: 18),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${_entries.length} songs cached',
                style: AppText.bodyM().copyWith(fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // ---------- Cache limit slider ----------
        Text('Cache limit', style: AppText.displayS(color: kText).copyWith(fontSize: 15)),
        Slider(
          value: sliderIndex,
          min: 0,
          max: (_kLimitOptions.length - 1).toDouble(),
          divisions: _kLimitOptions.length - 1,
          activeColor: kGreen,
          inactiveColor: kSurface,
          label: _limitLabel(_kLimitOptions[sliderIndex.round()]),
          onChanged: (v) => setState(() => _limitBytes =
              _kLimitOptions[v.round()] < 0 ? _kUnlimitedBytes : _kLimitOptions[v.round()]),
          onChangeEnd: (v) => _setLimit(v.round()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('500MB', style: AppText.bodyS()),
              Text('1GB', style: AppText.bodyS()),
              Text('2GB', style: AppText.bodyS()),
              Text('5GB', style: AppText.bodyS()),
              Text('∞', style: AppText.bodyS()),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ---------- Switches ----------
        _SwitchTile(
          title: 'WiFi only cache',
          value: _wifiOnly,
          onChanged: _setWifiOnly,
        ),
        _SwitchTile(
          title: 'Preload next song',
          value: _preloadNext,
          onChanged: _setPreloadNext,
        ),
        const SizedBox(height: 8),
        Text(
          'Liked songs protected hain',
          style: AppText.bodyS(color: kGreen).copyWith(fontSize: 12),
        ),
        const SizedBox(height: 20),

        // ---------- Clear buttons ----------
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kRed),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _entries.isEmpty ? null : _confirmClearAll,
                child: Text('Clear Cache', style: AppText.button(color: kRed)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kTextDim),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _entries.isEmpty ? null : _confirmClearUnprotected,
                child: Text('Clear Unprotected', style: AppText.button(color: kText)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // ---------- Cached songs list ----------
        if (_entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                children: [
                  const Icon(Icons.storage_rounded, color: kTextDim, size: 48),
                  const SizedBox(height: 10),
                  Text('Cache khaali hai', style: AppText.bodyM(color: kTextDim)),
                ],
              ),
            ),
          )
        else
          ...List.generate(_entries.length, (i) {
            final entry = _entries[i];
            final id = entry['id'] as String;
            final protected = (entry['protected'] as int? ?? 0) == 1;
            final size = (entry['size'] as num?)?.toInt() ?? 0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Dismissible(
                key: ValueKey(id),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  if (protected) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Protected song hai — pehle unprotect karo'),
                      ),
                    );
                    return false;
                  }
                  return true;
                },
                onDismissed: (_) => _deleteEntry(entry),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(
                    color: kRed,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                child: GestureDetector(
                  onLongPress: () => _toggleProtected(id, protected),
                  child: Material(
                    color: kBgElev,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: entry['thumb'] as String? ?? '',
                              width: 52,
                              height: 52,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                width: 52,
                                height: 52,
                                color: kSurface,
                              ),
                              errorWidget: (_, __, ___) => Container(
                                width: 52,
                                height: 52,
                                color: kSurface,
                                child: const Icon(Icons.music_note, color: kTextDim),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry['title'] as String? ?? 'Unknown',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.bodyM(color: kText).copyWith(fontSize: 13),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _formatMB(size),
                                  style: AppText.bodyS().copyWith(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            protected ? Icons.lock : Icons.lock_open,
                            color: protected ? kGreen : kTextDim,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        const SizedBox(height: 90),
      ],
    );
  }
}

// ---------------- Reusable switch row ----------------

class _SwitchTile extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: AppText.bodyL(color: kText))),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: kGreen,
          ),
        ],
      ),
    );
  }
}

// ---------------- Storage ring chart ----------------

class _RingPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  final Color bgColor;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 12.0;
    final center = size.center(Offset.zero);
    final radius = (size.width / 2) - strokeWidth / 2;

    final bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweep,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.bgColor != bgColor;
}
