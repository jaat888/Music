// lib/screens/settings_screen.dart
// Master settings screen — appearance/playback/downloads/cache/notifications/
// privacy/background/audio/advanced/about, sab SharedPreferences me save.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart';
import '../services/cache_service.dart';
import '../services/sleep_timer_service.dart';
import '../services/storage_service.dart';
import '../services/theme_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'about_screen.dart';
import 'background_settings_screen.dart';
import 'backup_restore_screen.dart';
import 'cache_manager_screen.dart';
import 'equalizer_screen.dart';
import 'help_screen.dart';

// ---------------- SharedPreferences keys ----------------
// NOTE: kai toggle yahan sirf UI/SharedPreferences state hain — inhe koi
// service abhi read nahi karta (jaise auto-cache, gapless, normalize etc.).
// Detail NOTES.md me hai.
const String _kGapless = 'setting_gapless';
const String _kCrossfade = 'setting_crossfade_seconds';
const String _kAudioQuality = 'setting_audio_quality';
const String _kAutoplay = 'setting_autoplay';
const String _kNormalizeVolume = 'setting_normalize_volume';

const String _kDownloadsWifiOnly = 'setting_downloads_wifi_only';
const String _kDownloadsAutoCleanup = 'setting_downloads_auto_cleanup';
const String _kDownloadQuality = 'setting_download_quality';

const String _kAutoCache = 'setting_auto_cache';
const String _kPreloadNext = 'cache_preload_next'; // CacheManagerScreen ke saath shared key

const String _kNotifNowPlaying = 'setting_notif_now_playing';
const String _kNotifNewReleases = 'setting_notif_new_releases';
const String _kNotifSoundVibration = 'setting_notif_sound_vibration';

const String _kPrivateSession = 'setting_private_session';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;

  // Appearance (ThemeService se load hote hain)
  ThemeMode _themeMode = ThemeMode.dark;
  AccentOption _accent = AccentOption.green;
  double _fontScale = 1.0;
  double _animationSpeed = 1.0;
  bool _dynamicColors = false;

  // Playback
  bool _gapless = true;
  int _crossfade = 0;
  String _audioQuality = 'High';
  bool _autoplay = true;
  bool _normalizeVolume = false;

  // Downloads
  bool _downloadsWifiOnly = true;
  bool _downloadsAutoCleanup = false;
  String _downloadQuality = 'High';

  // Cache
  bool _autoCache = true;
  bool _preloadNext = true;
  int _cacheSize = 0;

  // Notifications
  bool _notifNowPlaying = true;
  bool _notifNewReleases = true;
  bool _notifSoundVibration = true;

  // Privacy
  bool _privateSession = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // BUG FIX (v37 — "settings mein click nahi hota"): pehle is poore
  // function mein koi try/catch nahi tha. Agar in mein se KOI bhi ek await
  // (jaise `CacheService.instance.currentSize()` — cache folder abhi tak
  // bana hi na ho, ya koi bhi `ThemeService` call) kisi bhi wajah se ek
  // exception throw kar deta, to poora `_load()` future turant reject ho
  // jaata aur neeche wala `setState(() { ... _loading = false; })` KABHI
  // chalta hi nahi tha. Result: `_loading` hamesha `true` hi reh jaata,
  // screen hamesha sirf CircularProgressIndicator dikhati rehti — na koi
  // tile render hoti na koi tap kaam karta, screen hamesha ke liye "frozen"
  // lagti thi (bilkul "click nahi hota" jaisa symptom). Fix: har cheez
  // try/catch mein, aur `_loading = false` ek `finally` mein — kisi ek
  // setting ke load fail hone se poori screen kabhi na atke, baaki
  // defaults ke saath hi normal render/tap-response ho.
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();

      final themeMode = await ThemeService.instance.getThemeMode();
      final accent = await ThemeService.instance.getAccent();
      final fontScale = await ThemeService.instance.getFontScale();
      final animationSpeed = await ThemeService.instance.getAnimationSpeed();
      final dynamicColors = await ThemeService.instance.isDynamicColors();
      int cacheSize = 0;
      try {
        cacheSize = await CacheService.instance.currentSize();
      } catch (e) {
        print('SettingsScreen: cache size load fail hua (non-fatal): $e');
      }

      if (!mounted) return;
      setState(() {
        _themeMode = themeMode;
        _accent = accent;
        _fontScale = fontScale;
        _animationSpeed = animationSpeed;
        _dynamicColors = dynamicColors;

        _gapless = prefs.getBool(_kGapless) ?? true;
        _crossfade = prefs.getInt(_kCrossfade) ?? 0;
        _audioQuality = prefs.getString(_kAudioQuality) ?? 'High';
        _autoplay = prefs.getBool(_kAutoplay) ?? true;
        _normalizeVolume = prefs.getBool(_kNormalizeVolume) ?? false;

        _downloadsWifiOnly = prefs.getBool(_kDownloadsWifiOnly) ?? true;
        _downloadsAutoCleanup = prefs.getBool(_kDownloadsAutoCleanup) ?? false;
        _downloadQuality = prefs.getString(_kDownloadQuality) ?? 'High';

        _autoCache = prefs.getBool(_kAutoCache) ?? true;
        _preloadNext = prefs.getBool(_kPreloadNext) ?? true;
        _cacheSize = cacheSize;

        _notifNowPlaying = prefs.getBool(_kNotifNowPlaying) ?? true;
        _notifNewReleases = prefs.getBool(_kNotifNewReleases) ?? true;
        _notifSoundVibration = prefs.getBool(_kNotifSoundVibration) ?? true;

        _privateSession = prefs.getBool(_kPrivateSession) ?? false;
      });
    } catch (e) {
      print('SettingsScreen: _load() fail hua: $e');
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _snack('Kuch settings load nahi ho payi — defaults dikha rahe hain');
        });
      }
    } finally {
      // Chahe upar kuch bhi fail ho jaaye, screen kabhi bhi hamesha ke
      // liye loading spinner pe atki na rahe — hamesha tiles render/tap
      // hone chahiye.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setBool(String key, bool value, VoidCallback update) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    setState(update);
  }

  Future<void> _setInt(String key, int value, VoidCallback update) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
    setState(update);
  }

  Future<void> _setString(String key, String value, VoidCallback update) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    setState(update);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- Dialogs ----------------

  Future<void> _showThemeModeDialog() async {
    final options = <ThemeMode, String>{
      ThemeMode.dark: 'Dark',
      ThemeMode.light: 'Light',
      ThemeMode.system: 'System',
    };
    final picked = await _showOptionsDialog<ThemeMode>(
      title: 'Theme',
      options: options,
      current: _themeMode,
    );
    if (picked == null) return;
    await ThemeService.instance.setThemeMode(picked);
    setState(() => _themeMode = picked);
  }

  Future<void> _showAnimationSpeedDialog() async {
    final options = <double, String>{0.5: 'Slow', 1.0: 'Normal', 1.5: 'Fast'};
    final picked = await _showOptionsDialog<double>(
      title: 'Animation Speed',
      options: options,
      current: _animationSpeed,
    );
    if (picked == null) return;
    await ThemeService.instance.setAnimationSpeed(picked);
    setState(() => _animationSpeed = picked);
  }

  Future<void> _showCrossfadeDialog() async {
    final options = <int, String>{0: 'Off', 3: '3 sec', 6: '6 sec', 12: '12 sec'};
    final picked = await _showOptionsDialog<int>(
      title: 'Crossfade',
      options: options,
      current: _crossfade,
    );
    if (picked == null) return;
    _setInt(_kCrossfade, picked, () => _crossfade = picked);
  }

  Future<void> _showQualityDialog({
    required String title,
    required String current,
    required ValueChanged<String> onPicked,
  }) async {
    final options = <String, String>{'Low': 'Low', 'Med': 'Medium', 'High': 'High'};
    final picked = await _showOptionsDialog<String>(
      title: title,
      options: options,
      current: current,
    );
    if (picked != null) onPicked(picked);
  }

  Future<void> _showSleepTimerDialog() async {
    // NEW (Part 2): -1 = "Song khatam hone tak" (current gaana khatam hote
    // hi pause, agla gaana shuru hi nahi hota). Ye sleep timer ab
    // `SleepTimerService` (global, screen-independent — dekho us file ka
    // comment) me store hota hai, isliye FullPlayerScreen se set kiya ho
    // to bhi yahan sahi state dikhta/kaam karta hai, aur is settings
    // screen ko band karne se ye cancel nahi hota.
    final options = <int, String>{
      15: '15 min',
      30: '30 min',
      60: '60 min',
      90: '90 min',
      -1: 'Song khatam hone tak',
      0: 'Off',
    };
    final picked = await _showOptionsDialog<int>(
      title: 'Sleep Timer',
      options: options,
      current: 0,
    );
    if (picked == null) return;
    if (picked == 0) {
      SleepTimerService.instance.cancel();
      _snack('Sleep timer off kar diya');
      return;
    }
    if (picked == -1) {
      SleepTimerService.instance.startEndOfTrack();
      _snack('Current gaana khatam hote hi music pause ho jayega');
      return;
    }
    SleepTimerService.instance.startDuration(Duration(minutes: picked));
    _snack('$picked min baad music pause ho jayega');
  }

  Future<T?> _showOptionsDialog<T>({
    required String title,
    required Map<T, String> options,
    required T current,
  }) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text(title, style: AppText.displayS()),
        content: RadioGroup<T>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.entries.map((e) {
              final selected = e.key == current;
              return RadioListTile<T>(
                value: e.key,
                activeColor: kGreen,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  e.value,
                  style: AppText.bodyL(color: selected ? kGreen : kText),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    Color confirmColor = kRed,
  }) async {
    final result = await showDialog<bool>(
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
            child: Text(confirmLabel, style: AppText.button(color: confirmColor)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------------- Actions ----------------

  Future<void> _pickAccent(AccentOption option) async {
    await ThemeService.instance.setAccent(option);
    setState(() => _accent = option);
  }

  Future<void> _clearAppData() async {
    final confirm = await _confirmDialog(
      title: 'App data clear karein?',
      message:
          'Ye downloads/cache/liked/playlists ke settings ke alawa saari '
          'SharedPreferences values reset kar dega. Ye undo nahi ho sakta.',
      confirmLabel: 'Clear Data',
    );
    if (!confirm) return;

    final prefs = await SharedPreferences.getInstance();
    // Settings prefix wale keys ko chhod ke sab clear karo
    final keysToKeep = prefs.getKeys().where((k) => k.startsWith('setting_') ||
        k.startsWith('theme_') ||
        k == 'accent_color' ||
        k == 'font_scale' ||
        k == 'animation_speed' ||
        k == 'dynamic_colors');
    final saved = <String, Object?>{};
    for (final k in keysToKeep) {
      final v = prefs.get(k);
      if (v != null) saved[k] = v;
    }
    await prefs.clear();
    for (final entry in saved.entries) {
      final v = entry.value;
      if (v is bool) await prefs.setBool(entry.key, v);
      if (v is int) await prefs.setInt(entry.key, v);
      if (v is double) await prefs.setDouble(entry.key, v);
      if (v is String) await prefs.setString(entry.key, v);
      if (v is List<String>) await prefs.setStringList(entry.key, v);
    }
    if (!mounted) return;
    _snack('App data clear ho gaya');
  }

  Future<void> _deleteAccount() async {
    final confirm = await _confirmDialog(
      title: 'Account delete karein?',
      message: 'Ye action permanent hai. Aapka saara data hat jayega.',
      confirmLabel: 'Delete',
    );
    if (!confirm) return;
    // NOTE: koi AuthService/backend nahi hai (poora app local-only) —
    // isliye ye sirf ek UI placeholder hai, jaisa ProfileScreen ka Logout.
    _snack('Delete Account — abhi koi account system nahi hai');
  }

  Future<void> _resetApp() async {
    final confirm = await _confirmDialog(
      title: 'Poora app reset karein?',
      message: 'Ye SAARI settings, cache, aur preferences clear kar dega. '
          'Downloads/liked/playlists DB me hi rahenge (alag se delete karna hoga).',
      confirmLabel: 'Reset App',
    );
    if (!confirm) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await CacheService.instance.clearAll();
    if (!mounted) return;
    _snack('App reset ho gaya');
    _load();
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    // ThemeService ko watch karna — accent/theme kahin aur se badle to bhi
    // ye screen rebuild ho jaaye.
    context.watch<ThemeService>();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Settings', style: AppText.displayM(color: kGreen).copyWith(fontSize: 24)),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kGreen))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                children: [
                  _buildSectionHeader('APPEARANCE'),
                  _buildNavTile(
                    icon: Icons.brightness_6,
                    title: 'Theme',
                    subtitle: switch (_themeMode) {
                      ThemeMode.dark => 'Dark',
                      ThemeMode.light => 'Light',
                      ThemeMode.system => 'System',
                    },
                    onTap: _showThemeModeDialog,
                  ),
                  _buildAccentTile(),
                  _buildSliderTile(
                    icon: Icons.text_fields,
                    title: 'Font Size',
                    value: _fontScale,
                    min: 0.8,
                    max: 1.3,
                    label: _fontScale.toStringAsFixed(2),
                    onChanged: (v) => setState(() => _fontScale = v),
                    onChangeEnd: (v) => ThemeService.instance.setFontScale(v),
                  ),
                  _buildNavTile(
                    icon: Icons.speed,
                    title: 'Animation Speed',
                    subtitle: _animationSpeed <= 0.5
                        ? 'Slow'
                        : (_animationSpeed >= 1.5 ? 'Fast' : 'Normal'),
                    onTap: _showAnimationSpeedDialog,
                  ),
                  _buildSwitchTile(
                    icon: Icons.palette,
                    title: 'Dynamic Colors',
                    subtitle: 'Wallpaper se colors nikalo (placeholder)',
                    value: _dynamicColors,
                    onChanged: (v) async {
                      await ThemeService.instance.setDynamicColors(v);
                      setState(() => _dynamicColors = v);
                    },
                  ),

                  _buildSectionHeader('PLAYBACK'),
                  _buildSwitchTile(
                    icon: Icons.blur_linear,
                    title: 'Gapless Playback',
                    value: _gapless,
                    onChanged: (v) => _setBool(_kGapless, v, () => _gapless = v),
                  ),
                  _buildNavTile(
                    icon: Icons.swap_horiz,
                    title: 'Crossfade',
                    subtitle: _crossfade == 0 ? 'Off' : '$_crossfade sec',
                    onTap: _showCrossfadeDialog,
                  ),
                  _buildNavTile(
                    icon: Icons.high_quality,
                    title: 'Audio Quality',
                    subtitle: _audioQuality,
                    onTap: () => _showQualityDialog(
                      title: 'Audio Quality',
                      current: _audioQuality,
                      onPicked: (v) =>
                          _setString(_kAudioQuality, v, () => _audioQuality = v),
                    ),
                  ),
                  _buildSwitchTile(
                    icon: Icons.play_circle_outline,
                    title: 'Auto-play',
                    value: _autoplay,
                    onChanged: (v) => _setBool(_kAutoplay, v, () => _autoplay = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.graphic_eq,
                    title: 'Normalize Volume',
                    value: _normalizeVolume,
                    onChanged: (v) {
                      _setBool(_kNormalizeVolume, v, () => _normalizeVolume = v);
                      // PART 1: pehle sirf SharedPreferences me save hota
                      // tha, koi service isse padhti hi nahi thi — ab
                      // turant live bhi apply karo (loudness enhancer
                      // on/off) taaki chalte gaane pe bhi turant asar dikhe.
                      audioHandler.setNormalizeVolume(v);
                    },
                  ),

                  _buildSectionHeader('DOWNLOADS'),
                  _buildSwitchTile(
                    icon: Icons.wifi,
                    title: 'WiFi Only',
                    value: _downloadsWifiOnly,
                    onChanged: (v) =>
                        _setBool(_kDownloadsWifiOnly, v, () => _downloadsWifiOnly = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.cleaning_services,
                    title: 'Auto-cleanup',
                    subtitle: 'Purani downloads apne aap hatao',
                    value: _downloadsAutoCleanup,
                    onChanged: (v) =>
                        _setBool(_kDownloadsAutoCleanup, v, () => _downloadsAutoCleanup = v),
                  ),
                  _buildNavTile(
                    icon: Icons.folder,
                    title: 'Storage Location',
                    subtitle: 'Music/SurSathi/',
                    onTap: null,
                  ),
                  _buildNavTile(
                    icon: Icons.download,
                    title: 'Download Quality',
                    subtitle: _downloadQuality,
                    onTap: () => _showQualityDialog(
                      title: 'Download Quality',
                      current: _downloadQuality,
                      onPicked: (v) =>
                          _setString(_kDownloadQuality, v, () => _downloadQuality = v),
                    ),
                  ),

                  _buildSectionHeader('CACHE'),
                  _buildSwitchTile(
                    icon: Icons.offline_bolt,
                    title: 'Auto-cache',
                    subtitle: 'Play hote hi gaana cache ho jaaye',
                    value: _autoCache,
                    onChanged: (v) => _setBool(_kAutoCache, v, () => _autoCache = v),
                  ),
                  FutureBuilder<String>(
                    future: StorageService.formatBytes(_cacheSize),
                    builder: (context, snap) {
                      return _buildNavTile(
                        icon: Icons.storage,
                        title: 'Cache Limit',
                        subtitle: snap.data ?? '...',
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const CacheManagerScreen()),
                          );
                          _load();
                        },
                      );
                    },
                  ),
                  _buildSwitchTile(
                    icon: Icons.queue_music,
                    title: 'Preload Next Song',
                    value: _preloadNext,
                    onChanged: (v) => _setBool(_kPreloadNext, v, () => _preloadNext = v),
                  ),
                  _buildNavTile(
                    icon: Icons.lock,
                    title: 'Liked Songs Protected',
                    subtitle: 'Hamesha ON — kabhi cache se nahi hatengi',
                    onTap: null,
                    enabled: false,
                  ),

                  _buildSectionHeader('NOTIFICATIONS'),
                  _buildSwitchTile(
                    icon: Icons.music_note,
                    title: 'Now Playing',
                    value: _notifNowPlaying,
                    onChanged: (v) =>
                        _setBool(_kNotifNowPlaying, v, () => _notifNowPlaying = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.new_releases,
                    title: 'New Releases',
                    value: _notifNewReleases,
                    onChanged: (v) =>
                        _setBool(_kNotifNewReleases, v, () => _notifNewReleases = v),
                  ),
                  _buildSwitchTile(
                    icon: Icons.vibration,
                    title: 'Sound + Vibration',
                    value: _notifSoundVibration,
                    onChanged: (v) =>
                        _setBool(_kNotifSoundVibration, v, () => _notifSoundVibration = v),
                  ),

                  _buildSectionHeader('PRIVACY'),
                  _buildSwitchTile(
                    icon: Icons.visibility_off,
                    title: 'Private Session',
                    subtitle: 'Is session ka data history me save nahi hoga',
                    value: _privateSession,
                    onChanged: (v) => _setBool(_kPrivateSession, v, () => _privateSession = v),
                  ),
                  _buildNavTile(
                    icon: Icons.delete_sweep,
                    title: 'Clear App Data',
                    onTap: _clearAppData,
                    danger: true,
                  ),
                  _buildNavTile(
                    icon: Icons.person_remove,
                    title: 'Delete Account',
                    onTap: _deleteAccount,
                    danger: true,
                  ),

                  _buildSectionHeader('BACKGROUND'),
                  _buildNavTile(
                    icon: Icons.settings_backup_restore,
                    title: 'Background & Battery',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const BackgroundSettingsScreen()),
                    ),
                  ),

                  _buildSectionHeader('AUDIO'),
                  _buildNavTile(
                    icon: Icons.equalizer,
                    title: 'Equalizer',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const EqualizerScreen()),
                    ),
                  ),
                  _buildNavTile(
                    icon: Icons.bedtime,
                    title: 'Sleep Timer',
                    onTap: _showSleepTimerDialog,
                  ),

                  _buildSectionHeader('ADVANCED'),
                  _buildNavTile(
                    icon: Icons.backup,
                    title: 'Backup & Restore',
                    subtitle: 'Playlists + liked songs ko JSON me export/import karo',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const BackupRestoreScreen()),
                    ),
                  ),
                  _buildNavTile(
                    icon: Icons.restart_alt,
                    title: 'Reset App',
                    onTap: _resetApp,
                    danger: true,
                  ),

                  _buildSectionHeader('ABOUT'),
                  _buildNavTile(
                    icon: Icons.info_outline,
                    title: 'About SurSathi',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AboutScreen()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Text('Version 1.0.0', style: AppText.bodyS(color: kTextDim)),
                  ),
                  _buildNavTile(
                    icon: Icons.help_outline,
                    title: 'Help & FAQ',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const HelpScreen()),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ---------------- Reusable pieces ----------------

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8, left: 4),
      child: Text(
        title,
        style: AppText.label(color: kGreen).copyWith(letterSpacing: 1.2),
      ),
    );
  }

  Widget _buildTileShell({required Widget child, bool enabled = true}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Opacity(opacity: enabled ? 1 : 0.5, child: child),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _buildTileShell(
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

  Widget _buildNavTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback? onTap,
    bool danger = false,
    bool enabled = true,
  }) {
    return _buildTileShell(
      enabled: enabled,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: danger ? kRed : kTextDim),
        title: Text(
          title,
          style: AppText.bodyL(color: danger ? kRed : kText),
        ),
        subtitle: subtitle != null
            ? Text(subtitle, style: AppText.bodyS().copyWith(fontSize: 12))
            : null,
        trailing: onTap != null && enabled
            ? Icon(Icons.chevron_right, color: kTextDim, size: 20)
            : (!enabled ? Icon(Icons.lock, color: kTextDim, size: 16) : null),
        onTap: enabled ? onTap : null,
      ),
    );
  }

  Widget _buildAccentTile() {
    return _buildTileShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(Icons.color_lens, color: kTextDim),
            const SizedBox(width: 16),
            Expanded(
              child: Text('Accent Color', style: AppText.bodyL(color: kText)),
            ),
            ...AccentOption.values.map((option) {
              final selected = option == _accent;
              return Padding(
                padding: const EdgeInsets.only(left: 6),
                child: GestureDetector(
                  onTap: () => _pickAccent(option),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: option.color,
                      border: selected
                          ? Border.all(color: kText, width: 2)
                          : null,
                    ),
                    child: selected
                        ? const Icon(Icons.check, color: Colors.white, size: 14)
                        : null,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildSliderTile({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required String label,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return _buildTileShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: kTextDim),
                const SizedBox(width: 16),
                Text(title, style: AppText.bodyL(color: kText)),
                const Spacer(),
                Text(label, style: AppText.bodyS(color: kGreen)),
              ],
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              activeColor: kGreen,
              inactiveColor: kSurface,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ],
        ),
      ),
    );
  }
}
