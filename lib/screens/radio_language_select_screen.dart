// lib/screens/radio_language_select_screen.dart
// Part 8 — Radio Mode Phase 4: multi-language selection.
// Standalone UI; playback/resolve pipeline untouched.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/radio_service.dart';
import 'radio_player_screen.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

class RadioLanguageOption {
  final String code;
  final String name;
  final String nativeName;
  final String emoji;
  final String query;

  const RadioLanguageOption({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.emoji,
    required this.query,
  });
}

class RadioLanguageSelectScreen extends StatefulWidget {
  const RadioLanguageSelectScreen({super.key});

  static const languages = <RadioLanguageOption>[
    RadioLanguageOption(
      code: 'bollywood',
      name: 'Bollywood',
      nativeName: 'Hindi film songs',
      emoji: '🎬',
      query: 'bollywood hits songs',
    ),
    RadioLanguageOption(
      code: 'punjabi',
      name: 'Punjabi',
      nativeName: 'ਪੰਜਾਬੀ ਗਾਣੇ',
      emoji: '🕺',
      query: 'punjabi hits songs',
    ),
    RadioLanguageOption(
      code: 'haryanvi',
      name: 'Haryanvi',
      nativeName: 'हरियाणवी गाने',
      emoji: '🎤',
      query: 'haryanvi hits songs',
    ),
  ];

  static const _prefsKey = 'radio_selected_languages';

  @override
  State<RadioLanguageSelectScreen> createState() =>
      _RadioLanguageSelectScreenState();
}

class _RadioLanguageSelectScreenState
    extends State<RadioLanguageSelectScreen> {
  final Set<String> _selected = <String>{};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
  }

  Future<void> _loadSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(RadioLanguageSelectScreen._prefsKey) ?? [];
    final validCodes = RadioLanguageSelectScreen.languages.map((e) => e.code).toSet();

    if (!mounted) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(saved.where(validCodes.contains));
      _loading = false;
    });

    // Keep RadioService's session state in sync even if this screen is opened
    // directly from another part of the app.
    RadioService.instance.setSelectedLanguages(_selected.toList());
  }

  void _toggle(String code) {
    setState(() {
      if (_selected.contains(code)) {
        _selected.remove(code);
      } else {
        _selected.add(code);
      }
    });
  }

  Future<void> _startRadio() async {
    if (_selected.isEmpty || _saving) return;
    setState(() => _saving = true);

    final ordered = RadioLanguageSelectScreen.languages
        .where((language) => _selected.contains(language.code))
        .map((language) => language.code)
        .toList();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(RadioLanguageSelectScreen._prefsKey, ordered);
    RadioService.instance.setSelectedLanguages(ordered);

    if (!mounted) return;
    setState(() => _saving = false);

    // Phase 5: selection directly opens the reel-style Radio Player.
    // Keep the selected list in the session so Reset/Change Language can
    // later return here with the same choices pre-ticked.
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => RadioPlayerScreen(languages: ordered)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canStart = _selected.isNotEmpty && !_saving && !_loading;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Radio Mode', style: AppText.titleL()),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Apni languages chuno', style: AppText.displayL()),
                        const SizedBox(height: 8),
                        Text(
                          'Ek ya jitni chaaho languages select karo. Radio in sabka mix banayega.',
                          style: AppText.bodyM(),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_selected.length} selected',
                          style: AppText.bodyS(color: kGreen),
                        ),
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
                        final selected = _selected.contains(language.code);
                        return Semantics(
                          button: true,
                          selected: selected,
                          label: '${language.name} language',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _toggle(language.code),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
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
                                    decoration: BoxDecoration(
                                      color: kSurface,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
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
                        onPressed: canStart ? _startRadio : null,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.radio),
                        label: Text(
                          _saving ? 'Saving...' : 'Start Radio',
                          style: AppText.button(),
                        ),
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
              ),
      ),
    );
  }
}
