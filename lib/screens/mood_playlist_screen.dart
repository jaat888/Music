// lib/screens/mood_playlist_screen.dart
// YouTube Music-style discovery: Mood/Genre or Language -> live playlists
// -> existing normal playlist/player flow. No Radio mode is involved here.

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/mood_catalog.dart';
import '../services/youtube_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'live_playlist_screen.dart';

class MoodPlaylistScreen extends StatelessWidget {
  const MoodPlaylistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Moods & Genres', style: AppText.titleL()),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                child: Text(
                  'YouTube Music se live playlists discover karo. Mood ya language choose karo.',
                  style: AppText.bodyM(),
                ),
              ),
            ),
            SliverToBoxAdapter(child: _sectionTitle('Mood & Genres')),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final mood = kMoodDefinitions[index];
                    return _DiscoveryCard(
                      label: mood.label,
                      emoji: mood.emoji,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MoodDiscoveryPlaylistsScreen(mood: mood),
                        ),
                      ),
                    );
                  },
                  childCount: kMoodDefinitions.length,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.72,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _sectionTitle('Languages')),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final language = kMoodLanguages[index];
                    return _DiscoveryCard(
                      label: language.label,
                      emoji: language.emoji,
                      subtitle: language.nativeName,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MoodDiscoveryPlaylistsScreen(language: language),
                        ),
                      ),
                    );
                  },
                  childCount: kMoodLanguages.length,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.72,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Text(title, style: AppText.displayS()),
      );
}

class _DiscoveryCard extends StatelessWidget {
  final String label;
  final String emoji;
  final String? subtitle;
  final VoidCallback onTap;

  const _DiscoveryCard({
    required this.label,
    required this.emoji,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBgElev,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 31)),
              const SizedBox(height: 8),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyL()),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyS()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class MoodDiscoveryPlaylistsScreen extends StatefulWidget {
  final MoodDefinition? mood;
  final LanguageDefinition? language;

  const MoodDiscoveryPlaylistsScreen({super.key, this.mood, this.language})
      : assert((mood == null) != (language == null));

  @override
  State<MoodDiscoveryPlaylistsScreen> createState() => _MoodDiscoveryPlaylistsScreenState();
}

class _MoodDiscoveryPlaylistsScreenState extends State<MoodDiscoveryPlaylistsScreen> {
  bool _loading = true;
  List<YtPlaylistPreview> _playlists = const [];
  String? _error;

  String get _title => widget.mood?.label ?? widget.language!.label;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<YtPlaylistPreview> playlists;
      if (widget.mood != null) {
        playlists = await _loadMoodPlaylists(widget.mood!);
      } else {
        playlists = await YoutubeService.instance.searchPlaylistsAll(widget.language!.query, max: 80);
      }
      final deduped = <String, YtPlaylistPreview>{};
      for (final playlist in playlists) {
        if (playlist.id.isNotEmpty && playlist.title.trim().isNotEmpty) {
          deduped[playlist.id] = playlist;
        }
      }
      if (!mounted) return;
      setState(() {
        _playlists = deduped.values.toList();
        _error = _playlists.isEmpty ? 'Abhi playlists nahi mil paayi. Pull karke dobara try karo.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _playlists = const [];
        _error = 'Playlists load nahi ho paayi: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<YtPlaylistPreview>> _loadMoodPlaylists(MoodDefinition mood) async {
    final categories = await YoutubeService.instance.getMoodGenreCategories();
    final aliases = mood.categoryAliases.map(_normalize).where((e) => e.isNotEmpty).toSet();

    for (final category in categories) {
      final title = _normalize(category.title);
      if (aliases.contains(title) || aliases.any((alias) => title == alias || title.contains(alias))) {
        final live = await YoutubeService.instance.getMoodGenrePlaylists(category.params, max: 100);
        if (live.isNotEmpty) return live;
      }
    }

    // Category not available in the current YT Music experiment/locale:
    // playlist search remains a safe discovery fallback.
    return YoutubeService.instance.searchPlaylistsAll(mood.fallbackQuery, max: 80);
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(_title, style: AppText.titleL()),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: kGreen,
          backgroundColor: kBgElev,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _playlists.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(28),
        children: [
          const SizedBox(height: 100),
          Icon(Icons.playlist_remove, color: kTextDim, size: 54),
          const SizedBox(height: 14),
          Center(child: Text(_error!, textAlign: TextAlign.center, style: AppText.bodyM())),
        ],
      );
    }
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 18,
        childAspectRatio: .78,
      ),
      itemCount: _playlists.length,
      itemBuilder: (_, index) {
        final playlist = _playlists[index];
        return _PlaylistTile(
          playlist: playlist,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LivePlaylistScreen(
                playlistId: playlist.id,
                title: playlist.title,
                subtitle: playlist.subtitle,
                thumb: playlist.thumb,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final YtPlaylistPreview playlist;
  final VoidCallback onTap;

  const _PlaylistTile({required this.playlist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: playlist.thumb.isEmpty
                  ? Container(color: kSurface, child: const Center(child: Icon(Icons.queue_music, size: 42)))
                  : CachedNetworkImage(
                      imageUrl: playlist.thumb,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: kSurface,
                        child: const Center(child: Icon(Icons.queue_music, size: 42)),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(playlist.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyL()),
          const SizedBox(height: 2),
          Text(
            playlist.subtitle.isEmpty ? 'YouTube Music playlist' : playlist.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodyS(),
          ),
        ],
      ),
    );
  }
}
