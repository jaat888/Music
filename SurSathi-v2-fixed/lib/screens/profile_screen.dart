// lib/screens/profile_screen.dart
// User profile — avatar, stats row, sections list (liked/playlists/
// downloads/cache/stats/settings/about), logout.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/download_db.dart';
import '../db/liked_db.dart';
import '../db/playlist_db.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'about_screen.dart';
import 'cache_manager_screen.dart';
import 'downloads_screen.dart';
import 'library_screen.dart';
import 'liked_songs_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _loading = true;
  int _likedCount = 0;
  int _playlistCount = 0;
  int _downloadCount = 0;
  int _hours = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final liked = await LikedDB.instance.getAll();
    final playlists = await PlaylistDB.instance.getAllPlaylists();
    final downloads = await DownloadDB.instance.getAll();
    // NOTE: koi real listening-time tracker abhi nahi hai — 'listened_seconds'
    // wahi placeholder SharedPreferences key hai jo StatsScreen (Batch 12)
    // bhi use karti hai (NOTES.md dekho).
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('listened_seconds') ?? 0;

    if (!mounted) return;
    setState(() {
      _likedCount = liked.length;
      _playlistCount = playlists.length;
      _downloadCount = downloads.length;
      _hours = (seconds / 3600).round();
      _loading = false;
    });
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Logout karein?', style: AppText.displayS()),
        content: Text('Aap SurSathi se logout ho jaayenge.', style: AppText.bodyM()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Logout', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    // NOTE: app me koi AuthService/backend nahi hai (poora app local-only
    // hai — YouTube search + local DB), isliye logout sirf ek UI
    // placeholder hai. (NOTES.md dekho)
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logout — abhi koi account system nahi hai')),
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
          'Profile',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: kText),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kGreen))
            : RefreshIndicator(
                onRefresh: _load,
                color: kGreen,
                backgroundColor: kBgElev,
                child: _buildBody(),
              ),
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ---------- Header card ----------
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 24),
          decoration: BoxDecoration(
            color: kBgElev,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [kGreen, kBlue],
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'S',
                  style: AppText.displayL(color: kText)
                      .copyWith(fontSize: 36, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'SurSathi User',
                style: AppText.displayM(color: kText).copyWith(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text('Haryana', style: AppText.bodyM().copyWith(fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ---------- Stats row ----------
        Row(
          children: [
            _StatBox(label: 'Liked', value: _likedCount),
            _StatBox(label: 'Playlists', value: _playlistCount),
            _StatBox(label: 'Downloads', value: _downloadCount),
            _StatBox(label: 'Hours', value: _hours),
          ],
        ),
        const SizedBox(height: 20),

        // ---------- Sections ----------
        _SectionTile(
          icon: Icons.favorite,
          title: 'Liked Songs',
          trailing: '$_likedCount',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
          ).then((_) => _load()),
        ),
        _SectionTile(
          icon: Icons.queue_music,
          title: 'My Playlists',
          trailing: '$_playlistCount',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LibraryScreen()),
          ).then((_) => _load()),
        ),
        _SectionTile(
          icon: Icons.download_rounded,
          title: 'Downloads',
          trailing: '$_downloadCount',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DownloadsScreen()),
          ).then((_) => _load()),
        ),
        _SectionTile(
          icon: Icons.storage_rounded,
          title: 'Cache Manager',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CacheManagerScreen()),
          ),
        ),
        _SectionTile(
          icon: Icons.bar_chart_rounded,
          title: 'Statistics',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StatsScreen()),
          ),
        ),
        _SectionTile(
          icon: Icons.settings,
          title: 'Settings',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        _SectionTile(
          icon: Icons.info_outline,
          title: 'About',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AboutScreen()),
          ),
        ),
        const SizedBox(height: 20),

        // ---------- Logout ----------
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: kRed),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _logout,
            icon: const Icon(Icons.logout, color: kRed),
            label: Text('Logout', style: AppText.button(color: kRed)),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

// ---------------- Stats box (reusable) ----------------

class _StatBox extends StatelessWidget {
  final String label;
  final int value;

  const _StatBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: kBgElev,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: AppText.displayS(color: kGreen).copyWith(fontSize: 18),
            ),
            const SizedBox(height: 4),
            Text(label, style: AppText.bodyS().copyWith(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ---------------- Section tile (reusable) ----------------

class _SectionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback onTap;

  const _SectionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: kBgElev,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: kGreen),
                const SizedBox(width: 14),
                Expanded(child: Text(title, style: AppText.bodyL(color: kText))),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(trailing!, style: AppText.bodyS()),
                  ),
                const Icon(Icons.chevron_right, color: kTextDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
