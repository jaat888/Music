// lib/screens/create_playlist_screen.dart
// Playlist banane/edit karne ki screen — cover (emoji/gradient/solid), naam, description, switches.

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/playlist.dart';
import '../db/playlist_db.dart';

// ---------------- Cover style constants ----------------
// playlist_detail_screen.dart aur add_to_playlist_sheet.dart bhi inhi
// constants/coverGradientFor() ko import karke reuse karte hain, taaki
// cover ka look sab jagah consistent rahe.

const List<String> kPlaylistEmojis = [
  '🎵', '🎬', '💕', '🎉', '🌙', '🎤', '🔥', '💪',
  '🎸', '🎧', '⭐', '🌈', '🍕', '☕', '🚗', '🏖️',
  '🎮', '📚', '🌸', '⚡',
];

final Map<String, LinearGradient> kPlaylistGradients = {
  'green_blue': const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [kGreen, kBlue],
  ),
  'blue_purple': const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [kBlue, kPurple],
  ),
  'pink_orange': const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF6B9D), Color(0xFFFFA751)],
  ),
  'sunset': const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF6B6B), Color(0xFFFFD93D)],
  ),
  'ocean': const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00C6FB), Color(0xFF005BEA)],
  ),
  'forest': const LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
  ),
};

final Map<String, Color> kPlaylistSolidColors = {
  'solid_green': kGreen,
  'solid_blue': kBlue,
  'solid_purple': kPurple,
  'solid_red': kRed,
  'solid_amber': const Color(0xFFFFC107),
  'solid_cyan': const Color(0xFF00BCD4),
  'solid_deep_purple': const Color(0xFF9C27B0),
  'solid_orange': const Color(0xFFFF5722),
};

// Playlist.coverGradient me jo bhi key save hai, uske hisaab se gradient
// nikal deta hai (gradient preset ya solid color dono). Unknown/'default'
// key pe green_blue fallback hota hai.
LinearGradient coverGradientFor(String key) {
  if (kPlaylistGradients.containsKey(key)) return kPlaylistGradients[key]!;
  if (kPlaylistSolidColors.containsKey(key)) {
    final c = kPlaylistSolidColors[key]!;
    return LinearGradient(colors: [c, c]);
  }
  return kPlaylistGradients['green_blue']!;
}

class CreatePlaylistScreen extends StatefulWidget {
  final String? editId;
  const CreatePlaylistScreen({super.key, this.editId});

  @override
  State<CreatePlaylistScreen> createState() => _CreatePlaylistScreenState();
}

class _CreatePlaylistScreenState extends State<CreatePlaylistScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController(); // BATCH 14B: ab DB me save hota hai

  String _emoji = '';
  String _coverKey = 'green_blue';
  bool _collaborative = false;
  bool _private = false; // BATCH 14B: ab DB me save hota hai
  bool _loading = false;
  bool _nameError = false;
  String? _shareCode; // sirf UI display ke liye, DB me save nahi hota

  bool get _isEdit => widget.editId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) _loadExisting();
  }

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    final p = await PlaylistDB.instance.getPlaylist(widget.editId!);
    if (!mounted) return;
    if (p != null) {
      _nameCtrl.text = p.name;
      _descCtrl.text = p.description ?? '';
      _emoji = p.coverEmoji;
      _coverKey = p.coverGradient;
      _collaborative = p.isCollaborative;
      _private = p.isPrivate;
    }
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = true);
      return;
    }

    final description = _descCtrl.text.trim();

    if (_isEdit) {
      // Edit mode — sirf changed fields update karo, songs mapping
      // (playlist_songs table) bilkul untouched rehti hai.
      final id = widget.editId!;
      await PlaylistDB.instance.updatePlaylist(
        id,
        name: name,
        description: description,
        coverEmoji: _emoji,
        coverGradient: _coverKey,
        isPrivate: _private,
        isCollaborative: _collaborative,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ Saved')),
      );
      Navigator.pop(context, id);
      return;
    }

    // Naya create mode — fresh Playlist banao, description/isPrivate
    // bhi ab Playlist model me hi save ho jaate hain.
    final id = Uuid().v4();
    final playlist = Playlist(
      id: id,
      name: name,
      description: description.isEmpty ? null : description,
      coverEmoji: _emoji,
      coverGradient: _coverKey,
      songIds: const [],
      createdAt: DateTime.now(),
      isCollaborative: _collaborative,
      isPrivate: _private,
    );
    await PlaylistDB.instance.createPlaylist(playlist);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✓ Saved')),
    );
    Navigator.pop(context, id);
  }

  void _openCoverPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBgElev,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _CoverPickerSheet(
        currentEmoji: _emoji,
        currentKey: _coverKey,
        onEmojiPicked: (e) => setState(() => _emoji = e == _emoji ? '' : e),
        onGradientPicked: (k) => setState(() => _coverKey = k),
      ),
    );
  }

  String _genShareCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final seed = DateTime.now().millisecondsSinceEpoch;
    return List.generate(6, (i) => chars[(seed ~/ (i + 7)) % chars.length]).join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          _isEdit ? 'Edit Playlist' : 'New Playlist',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('Save', style: AppText.button(color: kGreen)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kGreen))
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: _openCoverPicker,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(
                              gradient: coverGradientFor(_coverKey),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            alignment: Alignment.center,
                            child: _emoji.isNotEmpty
                                ? Text(_emoji, style: const TextStyle(fontSize: 56))
                                : const Icon(Icons.music_note,
                                    color: Colors.white70, size: 40),
                          ),
                          Positioned(
                            bottom: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration:  BoxDecoration(
                                color: kBg,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.edit, color: kGreen, size: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _nameCtrl,
                    style: AppText.bodyL(color: kText),
                    cursorColor: kGreen,
                    onChanged: (_) {
                      if (_nameError) setState(() => _nameError = false);
                    },
                    decoration: InputDecoration(
                      hintText: 'Playlist ka naam...',
                      hintStyle: AppText.bodyL(color: kTextDim),
                      filled: true,
                      fillColor: kBgElev,
                      errorText: _nameError ? 'Naam khali nahi ho sakta' : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: kGreen, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // BATCH 14B: description ab Playlist model ke saath
                  // save/load hoti hai (pehle sirf UI me thi).
                  TextField(
                    controller: _descCtrl,
                    maxLines: 2,
                    style: AppText.bodyM(color: kText),
                    cursorColor: kGreen,
                    decoration: InputDecoration(
                      hintText: 'Description (optional)...',
                      hintStyle: AppText.bodyM(color: kTextDim),
                      filled: true,
                      fillColor: kBgElev,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: kGreen, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeColor: kGreen,
                    title: Text('Collaborative', style: AppText.bodyL(color: kText)),
                    subtitle: Text(
                      _shareCode != null ? 'Code: $_shareCode' : 'Doston ke saath share karo',
                      style: AppText.bodyS(),
                    ),
                    value: _collaborative,
                    onChanged: (v) {
                      setState(() {
                        _collaborative = v;
                        _shareCode = v ? _genShareCode() : null;
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeColor: kGreen,
                    title: Text('Private', style: AppText.bodyL(color: kText)),
                    subtitle: Text('Sirf tumhe dikhegi', style: AppText.bodyS()),
                    value: _private,
                    onChanged: (v) => setState(() => _private = v),
                  ),
                ],
              ),
            ),
    );
  }
}

// ---------------- Cover picker bottom sheet (Emoji / Gradient / Solid tabs) ----------------

class _CoverPickerSheet extends StatefulWidget {
  final String currentEmoji;
  final String currentKey;
  final ValueChanged<String> onEmojiPicked;
  final ValueChanged<String> onGradientPicked;

  const _CoverPickerSheet({
    required this.currentEmoji,
    required this.currentKey,
    required this.onEmojiPicked,
    required this.onGradientPicked,
  });

  @override
  State<_CoverPickerSheet> createState() => _CoverPickerSheetState();
}

class _CoverPickerSheetState extends State<_CoverPickerSheet> {
  int _tab = 0; // 0 = emoji, 1 = gradient, 2 = solid

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: kTextDim.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _tabButton('Emoji', 0),
                _tabButton('Gradient', 1),
                _tabButton('Solid', 2),
              ],
            ),
            const SizedBox(height: 16),
            if (_tab == 0) _emojiGrid(),
            if (_tab == 1) _gradientGrid(),
            if (_tab == 2) _solidGrid(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final selected = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = index),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? kGreen.withValues(alpha: 0.15) : kSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? kGreen : Colors.transparent),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppText.bodyM(color: selected ? kGreen : kTextDim),
          ),
        ),
      ),
    );
  }

  Widget _emojiGrid() {
    return SizedBox(
      height: 220,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: kPlaylistEmojis.length,
        itemBuilder: (context, i) {
          final e = kPlaylistEmojis[i];
          final selected = e == widget.currentEmoji;
          return GestureDetector(
            onTap: () {
              widget.onEmojiPicked(e);
              Navigator.pop(context);
            },
            child: Container(
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? kGreen : Colors.transparent,
                  width: 2,
                ),
              ),
              alignment: Alignment.center,
              child: Text(e, style: const TextStyle(fontSize: 24)),
            ),
          );
        },
      ),
    );
  }

  Widget _gradientGrid() {
    final keys = kPlaylistGradients.keys.toList();
    return SizedBox(
      height: 140,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.4,
        ),
        itemCount: keys.length,
        itemBuilder: (context, i) {
          final key = keys[i];
          final selected = key == widget.currentKey;
          return GestureDetector(
            onTap: () {
              widget.onGradientPicked(key);
              Navigator.pop(context);
            },
            child: Container(
              decoration: BoxDecoration(
                gradient: kPlaylistGradients[key],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _solidGrid() {
    final keys = kPlaylistSolidColors.keys.toList();
    return SizedBox(
      height: 100,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: keys.length,
        itemBuilder: (context, i) {
          final key = keys[i];
          final selected = key == widget.currentKey;
          return GestureDetector(
            onTap: () {
              widget.onGradientPicked(key);
              Navigator.pop(context);
            },
            child: Container(
              decoration: BoxDecoration(
                color: kPlaylistSolidColors[key],
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
