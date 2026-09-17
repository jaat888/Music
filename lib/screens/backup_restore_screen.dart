// lib/screens/backup_restore_screen.dart
// Part 4 — Playlists+likes ko JSON file me export/import karne ki UI.
// settings_screen.dart ke ADVANCED section ke purane "Backup"/"Restore"
// stub tiles (jo sirf SnackBar dikhate the, koi asli kaam nahi karte the)
// ab isi screen par le jaate hain.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  BackupSummary? _currentSummary;
  bool _loadingSummary = true;
  bool _exporting = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() => _loadingSummary = true);
    try {
      final s = await BackupService.instance.exportSummary();
      if (!mounted) return;
      setState(() => _currentSummary = s);
    } catch (e) {
      print('BACKUP_RESTORE _loadSummary ERROR: $e');
    } finally {
      if (mounted) setState(() => _loadingSummary = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final file = await BackupService.instance.exportToFile();
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'SurSathi backup — playlists + liked songs',
      );
    } catch (e) {
      _snack('Export fail ho gaya: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return; // user ne cancel kar diya

    final file = File(path);
    BackupSummary preview;
    try {
      preview = await BackupService.instance.previewFile(file);
    } catch (e) {
      _snack('Ye file sahi backup JSON nahi lagti: $e');
      return;
    }

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Backup restore karein?', style: AppText.displayS()),
        content: Text(
          'File me ${preview.playlists} playlists (${preview.playlistSongs} songs) '
          'aur ${preview.likedSongs} liked songs hain.\n\n'
          'Ye tumhare existing data me MERGE hoga (kuch delete nahi hoga) — '
          'same playlist dobara import karna bhi safe hai.',
          style: AppText.bodyM(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Restore', style: AppText.button(color: kGreen)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _importing = true);
    try {
      final result = await BackupService.instance.importFromFile(file);
      _snack(
        '${result.playlists} playlists, ${result.likedSongs} liked songs restore ho gaye',
      );
      await _loadSummary();
    } catch (e) {
      _snack('Restore fail ho gaya: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Backup & Restore', style: AppText.displayM(color: kGreen).copyWith(fontSize: 20)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Playlists aur liked songs ko ek JSON file me export karo — '
              'phone change ya reinstall karne pe wapas import kar sakte ho. '
              'Downloaded/cached audio files isme shamil nahi hain, sirf list data hai.',
              style: AppText.bodyM(color: kTextDim),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kBgElev,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.backup, color: kGreen),
                      const SizedBox(width: 10),
                      Text('Export', style: AppText.bodyL(color: kText).copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_loadingSummary)
                    Text('Loading...', style: AppText.bodyS(color: kTextDim))
                  else if (_currentSummary != null)
                    Text(
                      '${_currentSummary!.playlists} playlists (${_currentSummary!.playlistSongs} songs), '
                      '${_currentSummary!.likedSongs} liked songs',
                      style: AppText.bodyS(color: kTextDim),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kGreen,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _exporting ? null : _export,
                      icon: _exporting
                          ?  SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: kBg),
                            )
                          : Icon(Icons.ios_share, color: kBg),
                      label: Text('Export & Share', style: AppText.button(color: kBg)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kBgElev,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.restore, color: kBlue),
                      const SizedBox(width: 10),
                      Text('Restore', style: AppText.bodyL(color: kText).copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pehle exported backup JSON file chuno.',
                    style: AppText.bodyS(color: kTextDim),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: kBlue),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _importing ? null : _import,
                      icon: _importing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: kBlue),
                            )
                          : const Icon(Icons.file_open, color: kBlue),
                      label: Text('Choose Backup File', style: AppText.button(color: kBlue)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
