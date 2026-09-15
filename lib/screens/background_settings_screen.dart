// lib/screens/background_settings_screen.dart
// Background play + battery optimization + audio focus settings.
// Saare toggles SharedPreferences me 'bg_' prefix ke saath save hote hain.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

const String _kContinueInBackground = 'bg_continue_in_background';
const String _kAutoResumeOnBoot = 'bg_auto_resume_on_boot';
const String _kPauseOnUnplug = 'bg_pause_on_headphone_unplug';
const String _kResumeAfterCall = 'bg_resume_after_call';
const String _kDuckOnNavigation = 'bg_duck_on_navigation';
const String _kDuckOnOtherApps = 'bg_duck_on_other_apps';

class BackgroundSettingsScreen extends StatefulWidget {
  const BackgroundSettingsScreen({super.key});

  @override
  State<BackgroundSettingsScreen> createState() => _BackgroundSettingsScreenState();
}

class _BackgroundSettingsScreenState extends State<BackgroundSettingsScreen> {
  bool _loading = true;

  bool _continueInBackground = true;
  bool _autoResumeOnBoot = false;
  bool _pauseOnUnplug = true;
  bool _resumeAfterCall = true;
  bool _duckOnNavigation = true;
  bool _duckOnOtherApps = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _continueInBackground = prefs.getBool(_kContinueInBackground) ?? true;
      _autoResumeOnBoot = prefs.getBool(_kAutoResumeOnBoot) ?? false;
      _pauseOnUnplug = prefs.getBool(_kPauseOnUnplug) ?? true;
      _resumeAfterCall = prefs.getBool(_kResumeAfterCall) ?? true;
      _duckOnNavigation = prefs.getBool(_kDuckOnNavigation) ?? true;
      _duckOnOtherApps = prefs.getBool(_kDuckOnOtherApps) ?? true;
      _loading = false;
    });
  }

  Future<void> _setBool(String key, bool value, VoidCallback update) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    setState(update);
  }

  void _openBatterySettings() {
    // NOTE: koi platform-specific battery-optimization plugin (jaise
    // `android_intent_plus` ke saath ACTION_IGNORE_BATTERY_OPTIMIZATIONS)
    // pubspec me nahi hai — isliye seedha OS settings kholna possible nahi.
    // Filhaal manual instructions dikhate hain (see NOTES.md).
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Manual: Settings → Battery → SurSathi → Unrestricted'),
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
          'Background & Battery',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 22),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kGreen))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildSectionHeader('BACKGROUND PLAY'),
                  _buildSwitchTile(
                    icon: Icons.play_circle_outline,
                    title: 'Continue in Background',
                    value: _continueInBackground,
                    onChanged: (v) => _setBool(
                        _kContinueInBackground, v, () => _continueInBackground = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.restart_alt,
                    title: 'Auto-resume on Boot',
                    value: _autoResumeOnBoot,
                    onChanged: (v) =>
                        _setBool(_kAutoResumeOnBoot, v, () => _autoResumeOnBoot = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.headset_off,
                    title: 'Pause on Headphone Unplug',
                    value: _pauseOnUnplug,
                    onChanged: (v) =>
                        _setBool(_kPauseOnUnplug, v, () => _pauseOnUnplug = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.call_end,
                    title: 'Resume after Call',
                    value: _resumeAfterCall,
                    onChanged: (v) =>
                        _setBool(_kResumeAfterCall, v, () => _resumeAfterCall = v),
                  ),

                  _buildSectionHeader('BATTERY OPTIMIZATION'),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline, color: kBlue, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Kuch phones (Xiaomi, Oppo, Vivo) background '
                            'service kill karte hain. SurSathi ke liye battery '
                            'optimization off karo.',
                            style: AppText.bodyM(color: kText).copyWith(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                      onPressed: _openBatterySettings,
                      child: Text(
                        'Open Battery Settings',
                        style: AppText.button(color: Colors.black),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  _buildSectionHeader('AUDIO FOCUS'),
                  _buildSwitchTile(
                    icon: Icons.navigation,
                    title: 'Duck on Navigation',
                    subtitle: 'Google Maps/Waze jaisi apps ke turn-by-turn pe volume kam',
                    value: _duckOnNavigation,
                    onChanged: (v) =>
                        _setBool(_kDuckOnNavigation, v, () => _duckOnNavigation = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.apps,
                    title: 'Duck on Other Apps',
                    value: _duckOnOtherApps,
                    onChanged: (v) =>
                        _setBool(_kDuckOnOtherApps, v, () => _duckOnOtherApps = v),
                  ),

                  _buildSectionHeader('SERVICE STATUS'),
                  _buildServiceStatusCard(),
                  const SizedBox(height: 20),
                ],
              ),
      ),
    );
  }

  Widget _buildServiceStatusCard() {
    return StreamBuilder(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final running = snapshot.data != null;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: kBgElev,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: running ? kGreen : kTextDim,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                running ? 'Running' : 'Idle',
                style: AppText.bodyL(color: running ? kGreen : kTextDim),
              ),
              const Spacer(),
              if (running)
                Text(
                  snapshot.data?.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyS().copyWith(fontSize: 12),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8, left: 4),
      child: Text(title, style: AppText.label(color: kGreen).copyWith(letterSpacing: 1.2)),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(icon, color: kTextDim),
        title: Text(title, style: AppText.bodyL(color: kText)),
        subtitle: subtitle != null
            ? Text(subtitle, style: AppText.bodyS().copyWith(fontSize: 12))
            : null,
        value: value,
        activeColor: kGreen,
        onChanged: onChanged,
      ),
    );
  }
}
