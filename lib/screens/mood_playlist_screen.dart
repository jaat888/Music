// lib/screens/mood_playlist_screen.dart
// Mood Mode entry flow:
// 1) language selection (same three strict language choices as Radio),
// 2) mood selection,
// 3) the existing hardened Radio player runs in strict Mood mode so it can
//    keep generating songs continuously instead of stopping at a short list.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/mood_catalog.dart';
import '../services/radio_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'radio_language_select_screen.dart';
import 'radio_player_screen.dart';

class MoodPlaylistScreen extends StatefulWidget {
  const MoodPlaylistScreen({super.key});

  @override
  State<MoodPlaylistScreen> createState() => _MoodPlaylistScreenState();
}

class _MoodPlaylistScreenState extends State<MoodPlaylistScreen> {
  static const _prefsKey = 'mood_selected_languages';

  final Set<String> _selectedLanguages = <String>{};
  bool _loading = true;
  bool _saving = false;
  bool _showMoodStep = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey) ?? [];
    final valid = RadioLanguageSelectScreen.languages.map((e) => e.code).toSet();
    if (!mounted) return;
    setState(() {
      _selectedLanguages
        ..clear()
        ..addAll(saved.where(valid.contains));
      _loading = false;
    });
  }

  void _toggleLanguage(String code) {
    setState(() {
      if (_selectedLanguages.contains(code)) {
        _selectedLanguages.remove(code);
      } else {
        _selectedLanguages.add(code);
      }
    });
  }

  Future<void> _continueToMood() async {
    if (_selectedLanguages.isEmpty || _saving) return;
    setState(() => _saving = true);
    final ordered = RadioLanguageSelectScreen.languages
        .where((language) => _selectedLanguages.contains(language.code))
        .map((language) => language.code)
        .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, ordered);
    RadioService.instance.setSelectedLanguages(ordered);
    if (!mounted) return;
    setState(() {
      _selectedLanguages
        ..clear()
        ..addAll(ordered);
      _saving = false;
      _showMoodStep = true;
    });
  }

  void _startMood(MoodProfile mood) {
    final languages = RadioLanguageSelectScreen.languages
        .where((language) => _selectedLanguages.contains(language.code))
        .map((language) => language.code)
        .toList();
    if (languages.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RadioPlayerScreen(
          languages: languages,
          moodCode: mood.code,
          moodLabel: mood.label,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: kBg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(_showMoodStep ? 'Choose Mood' : 'Mood Mode', style: AppText.titleL()),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_showMoodStep) {
              setState(() => _showMoodStep = false);
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: SafeArea(
        child: _showMoodStep ? _buildMoodStep() : _buildLanguageStep(),
      ),
    );
  }

  Widget _buildLanguageStep() {
    final canContinue = _selectedLanguages.isNotEmpty && !_saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pehle languages chuno', style: AppText.displayL()),
              const SizedBox(height: 8),
              Text(
                'Radio ki tarah ek ya jitni chaaho languages select karo. Uske baad mood choose karna hai.',
                style: AppText.bodyM(),
              ),
              const SizedBox(height: 8),
              Text('${_selectedLanguages.length} selected', style: AppText.bodyS(color: kGreen)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: RadioLanguageSelectScreen.languages.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, index) {
              final language = RadioLanguageSelectScreen.languages[index];
              final selected = _selectedLanguages.contains(language.code);
              return Semantics(
                button: true,
                selected: selected,
                label: '${language.name} language',
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _toggleLanguage(language.code),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: selected ? kGreen.withOpacity(.12) : kBgElev,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: selected ? kGreen : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14)),
                          child: Text(language.emoji, style: const TextStyle(fontSize: 26)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(language.name, style: AppText.bodyL()),
                              const SizedBox(height: 3),
                              Text(language.nativeName, style: AppText.bodyS()),
                            ],
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: selected
                              ? const Icon(Icons.check_circle, key: ValueKey(true), color: kGreen, size: 27)
                              : Icon(Icons.radio_button_unchecked, key: const ValueKey(false), color: kTextDim, size: 27),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: canContinue ? _continueToMood : null,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.arrow_forward),
              label: Text(_saving ? 'Saving...' : 'Next — Choose Mood', style: AppText.button()),
              style: ElevatedButton.styleFrom(
                backgroundColor: kGreen,
                disabledBackgroundColor: kSurface,
                disabledForegroundColor: kTextDim,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMoodStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text('Ab mood chuno', style: AppText.displayL()),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Sirf selected mood se strict-match gaane aayenge. Latest/new songs ko pehle priority milegi.',
            style: AppText.bodyM(),
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemCount: kMoodProfiles.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, index) {
              final mood = kMoodProfiles[index];
              return InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _startMood(mood),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: kBgElev,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: kSurface),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(16)),
                        child: Text(mood.emoji, style: const TextStyle(fontSize: 30)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(mood.label, style: AppText.bodyL()),
                            const SizedBox(height: 4),
                            Text('Strict ${mood.label} Radio • latest first • continuous play', style: AppText.bodyS(color: kTextDim)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: kTextDim),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
