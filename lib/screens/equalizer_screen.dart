// lib/screens/equalizer_screen.dart
// Equalizer UI — 10 bands + presets + bass boost + 3D surround + reverb.
// NOTE: just_audio me actual DSP limited hai, isliye filhaal sirf UI +
// SharedPreferences save hai (functional audio effect optional rakha gaya).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

// 10 bands — spec ke 7 (60/150/400/1k/2.4k/6k/12k) + 3 extra (20/16k/20k)
const List<int> _kBandFreqs = [
  20,
  60,
  150,
  400,
  1000,
  2400,
  6000,
  12000,
  16000,
  20000,
];

const Map<String, List<double>> _kPresets = {
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Rock': [4, 4, 3, -2, -4, -2, 2, 5, 6, 6],
  'Pop': [-1, -1, 2, 4, 4, 1, -1, -2, -2, 1],
  'Jazz': [3, 3, 2, 1, 2, -2, -2, 0, 2, 3],
  'Classical': [4, 4, 3, 2, 0, 0, 0, -2, -2, -3],
  'Bass': [7, 7, 6, 5, 3, 1, -1, -2, -3, -3],
  'Treble': [-3, -3, -3, -2, -1, 0, 2, 4, 5, 6],
  'Vocal': [-2, -2, -3, -2, 1, 4, 5, 4, 2, 0],
  'Dance': [5, 5, 4, 2, 0, -2, -1, 0, 2, 3],
  'Hip-Hop': [6, 6, 5, 3, 1, -1, -1, 1, 2, 2],
  'Acoustic': [3, 3, 3, 2, 1, 0, 1, 2, 2, 3],
  'Custom': [],
};

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
    _bands = List<double>.from(_kPresets['Flat']!);
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
        if (rawBands != null && rawBands.length == _kBandFreqs.length) {
          _bands = rawBands.map((e) => e.toDouble()).toList();
        }
      } catch (_) {
        // Corrupt data — defaults hi rehne do
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _saveSettings() async {
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Equalizer settings save ho gayi')),
    );
  }

  void _applyPreset(String name) {
    setState(() {
      _preset = name;
      final values = _kPresets[name];
      if (values != null && values.isNotEmpty) {
        _bands = List<double>.from(values);
      }
      // Custom select karne pe current slider values hi rehte hain
    });
  }

  void _onBandChanged(int index, double value) {
    setState(() {
      _bands[index] = value;
      _preset = 'Custom';
    });
  }

  void _reset() {
    setState(() {
      _preset = 'Flat';
      _bands = List<double>.from(_kPresets['Flat']!);
      _bassBoost = 0;
      _reverb = 0;
      _surround = false;
    });
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
      return const Scaffold(
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
                    onChanged: (v) => setState(() => _enabled = v),
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
                    children: _kPresets.keys.map((name) {
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
                      children: List.generate(_kBandFreqs.length, (i) {
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
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '${_freqLabel(_kBandFreqs[i])}Hz',
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
