// lib/screens/equalizer_screen.dart
// Equalizer UI — 10 bands + presets + bass boost + 3D surround + reverb.
//
// PART 2 (2026-09-17): pehle ye sirf UI + SharedPreferences save tha, koi
// bhi service isko actual audio pe apply nahi karti thi (naam/preset
// select karo ya slider hilao, gaana bilkul waisa hi bajta rehta tha).
// Ab band frequencies + preset curves `equalizer_presets.dart` se aate
// hain (background_service.dart bhi wahi file use karta hai), aur har
// change (enable toggle / preset tap / band slider) turant
// `audioHandler` ke through asli `AndroidEqualizer` (just_audio ke andar
// ExoPlayer effect) pe apply hota hai — is baar sach me sunai deta hai.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart';
import '../services/equalizer_presets.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  bool _loading = true;
  bool _enabled = true;
  String _preset = 'Flat';
  late List<double> _bands;
  double _bassBoost = 0;
  double _reverb = 0;
  bool _surround = false;

  @override
  void initState() {
    super.initState();
    _bands = List<double>.from(kEqualizerPresets['Flat']!);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('equalizer_settings');
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _enabled = data['enabled'] as bool? ?? true;
        _preset = data['preset'] as String? ?? 'Flat';
        _bassBoost = (data['bassBoost'] as num?)?.toDouble() ?? 0;
        _reverb = (data['reverb'] as num?)?.toDouble() ?? 0;
        _surround = data['surround'] as bool? ?? false;
        final rawBands = (data['bands'] as List?)?.cast<num>();
        if (rawBands != null && rawBands.length == kEqualizerBandFreqs.length) {
          _bands = rawBands.map((e) => e.toDouble()).toList();
        }
      } catch (_) {
        // Corrupt data — defaults hi rehne do
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    // NOTE: yahan dobara apply() nahi karte — background_service.dart apne
    // `_restoreSavedAudioSettings()` me app start hote hi ye same
    // SharedPreferences key khud padh ke apply kar chuka hota hai. Ye
    // sirf screen ke apne slider/switch state ko us se sync karta hai.
  }

  // BUG FIX (Part 2): pehle sirf "Save Custom" button dabane par
  // SharedPreferences me likha jaata tha — beech me app crash/kill ho
  // jaaye (ya user bina Save dabaye wapas chala jaaye) to sab kuch reset
  // ho jaata. Ab har change turant persist bhi hoti hai (silently, bina
  // SnackBar ke) — Save button sirf explicit confirmation ke liye hai.
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'equalizer_settings',
      jsonEncode({
        'enabled': _enabled,
        'preset': _preset,
        'bassBoost': _bassBoost,
        'reverb': _reverb,
        'surround': _surround,
        'bands': _bands,
      }),
    );
  }

  Future<void> _saveSettings() async {
    await _persist();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Equalizer settings save ho gayi')),
    );
  }

  // NEW (Part 2): band gains ko turant asli AndroidEqualizer pe bhejo —
  // agar `_enabled` false hai to bhi bhej dena harmless hai (band gains
  // set rehte hain, effect khud enable()/disable() se on/off hota hai).
  void _applyLive() {
    audioHandler.setEqualizerEnabled(_enabled);
    audioHandler.setEqualizerBands(_bands);
  }

  void _applyPreset(String name) {
    setState(() {
      _preset = name;
      final values = kEqualizerPresets[name];
      if (values != null && values.isNotEmpty) {
        _bands = List<double>.from(values);
      }
      // Custom select karne pe current slider values hi rehte hain
    });
    _applyLive();
    _persist();
  }

  void _onBandChanged(int index, double value) {
    setState(() {
      _bands[index] = value;
      _preset = 'Custom';
    });
    // NOTE: ye onChanged (drag ke har frame pe) hai — sirf local UI update.
    // Asli AndroidEqualizer call `onChangeEnd` (_onBandChangeEnd) me hota
    // hai taaki drag ke dauraan platform channel ko har pixel pe spam na
    // karna pade.
  }

  void _onBandChangeEnd(double _) {
    _applyLive();
    _persist();
  }

  void _setEnabled(bool v) {
    setState(() => _enabled = v);
    _applyLive();
    _persist();
  }

  void _reset() {
    setState(() {
      _preset = 'Flat';
      _bands = List<double>.from(kEqualizerPresets['Flat']!);
      _bassBoost = 0;
      _reverb = 0;
      _surround = false;
    });
    _applyLive();
    _persist();
  }

  String _freqLabel(int hz) {
    if (hz >= 1000) {
      final k = hz / 1000;
      final isWhole = k == k.roundToDouble();
      return isWhole ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
    }
    return '$hz';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return  Scaffold(
        backgroundColor: kBg,
        body: Center(child: CircularProgressIndicator(color: kGreen)),
      );
    }

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Equalizer', style: AppText.displayM(color: kGreen)),
        actions: [
          TextButton(
            onPressed: _reset,
            child: Text('Reset', style: AppText.button(color: kTextDim)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- Enable toggle ----------
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: kBgElev,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Enable Equalizer', style: AppText.bodyL()),
                  Switch(
                    value: _enabled,
                    activeColor: kGreen,
                    onChanged: _setEnabled,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ---------- Presets ----------
            Text('Presets', style: AppText.label()),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: IgnorePointer(
                ignoring: !_enabled,
                child: Opacity(
                  opacity: _enabled ? 1 : 0.4,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: kEqualizerPresets.keys.map((name) {
                      final selected = name == _preset;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(name),
                          selected: selected,
                          selectedColor: kGreen,
                          backgroundColor: kSurface,
                          labelStyle: AppText.bodyS(
                            color: selected ? Colors.black : kText,
                          ).copyWith(fontWeight: FontWeight.w600),
                          onSelected: (_) => _applyPreset(name),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ---------- Bands ----------
            Text('Bands', style: AppText.label()),
            const SizedBox(height: 8),
            IgnorePointer(
              ignoring: !_enabled,
              child: Opacity(
                opacity: _enabled ? 1 : 0.4,
                child: SizedBox(
                  height: 220,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: List.generate(kEqualizerBandFreqs.length, (i) {
                        return SizedBox(
                          width: 42,
                          child: Column(
                            children: [
                              Text(
                                '${_bands[i] >= 0 ? '+' : ''}${_bands[i].round()}',
                                style: AppText.bodyS(),
                              ),
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: kGreen,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: kGreen,
                                      trackHeight: 3,
                                      overlayShape:
                                          SliderComponentShape.noOverlay,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6,
                                      ),
                                    ),
                                    child: Slider(
                                      value: _bands[i],
                                      min: -12,
                                      max: 12,
                                      onChanged: (v) => _onBandChanged(i, v),
                                      onChangeEnd: _onBandChangeEnd,
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '${_freqLabel(kEqualizerBandFreqs[i])}Hz',
                                style: AppText.bodyS(),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ---------- Bass boost ----------
            IgnorePointer(
              ignoring: !_enabled,
              child: Opacity(
                opacity: _enabled ? 1 : 0.4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bass Boost · ${_bassBoost.round()}%',
                      style: AppText.bodyM(color: kText),
                    ),
                    Slider(
                      value: _bassBoost,
                      min: 0,
                      max: 100,
                      activeColor: kGreen,
                      inactiveColor: Colors.white24,
                      onChanged: (v) => setState(() => _bassBoost = v),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('3D Surround', style: AppText.bodyM(color: kText)),
                        Switch(
                          value: _surround,
                          activeColor: kGreen,
                          onChanged: (v) => setState(() => _surround = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Reverb · ${_reverb.round()}%',
                      style: AppText.bodyM(color: kText),
                    ),
                    Slider(
                      value: _reverb,
                      min: 0,
                      max: 100,
                      activeColor: kGreen,
                      inactiveColor: Colors.white24,
                      onChanged: (v) => setState(() => _reverb = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ---------- Save ----------
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saveSettings,
                child: Text(
                  'Save Custom',
                  style: AppText.button(color: Colors.black),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
