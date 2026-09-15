// lib/screens/about_screen.dart
// App info, developer credits, links, legal dialogs.

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

const String _kGithubUrl = 'https://github.com/jaat888/SurSathi';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _deviceLabel = '...';

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
  }

  // device_info_plus se Android model + version nikalo — sirf display ke
  // liye, koi functional use nahi. Kisi bhi error pe silently "Unknown".
  Future<void> _loadDeviceInfo() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (!mounted) return;
      setState(() {
        _deviceLabel = '${info.manufacturer} ${info.model} · Android ${info.version.release}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _deviceLabel = 'Unknown');
    }
  }

  Future<void> _openGithub() async {
    final uri = Uri.parse(_kGithubUrl);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) throw Exception('launch failed');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied: $_kGithubUrl')),
      );
    }
  }

  Future<void> _shareApp() async {
    await Share.share(
      'SurSathi try karo — Hindi/Haryanvi/Punjabi music player!\n$_kGithubUrl',
      subject: 'SurSathi',
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _showTextDialog(String title, String body) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text(title, style: AppText.displayS()),
        content: SingleChildScrollView(
          child: Text(body, style: AppText.bodyM()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close', style: AppText.button(color: kGreen)),
          ),
        ],
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
        title: Text('About', style: AppText.displayM(color: kGreen).copyWith(fontSize: 24)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Column(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(colors: [kGreen, kBlue]),
                    boxShadow: [
                      BoxShadow(
                        color: kGreen.withValues(alpha: 0.35),
                        blurRadius: 30,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.music_note, color: Colors.white, size: 50),
                ),
                const SizedBox(height: 20),
                Text('SurSathi', style: AppText.displayL(color: kGreen).copyWith(
                    fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('Version 1.0.0', style: AppText.bodyS().copyWith(fontSize: 13)),
                const SizedBox(height: 4),
                Text('Made with ❤️ in Haryana', style: AppText.bodyS().copyWith(fontSize: 13)),
              ],
            ),
            const SizedBox(height: 30),

            _buildInfoTile(icon: Icons.person, title: 'Developer', subtitle: 'Jaat888'),
            _buildInfoTile(
              icon: Icons.code,
              title: 'GitHub',
              subtitle: _kGithubUrl,
              onTap: _openGithub,
            ),
            _buildInfoTile(
              icon: Icons.share,
              title: 'Share App',
              onTap: _shareApp,
            ),
            _buildInfoTile(
              icon: Icons.star_border,
              title: 'Rate App',
              onTap: () => _snack('Play Store link jald hi aayega'),
            ),
            _buildInfoTile(
              icon: Icons.description_outlined,
              title: 'Open Source Licenses',
              onTap: () => _showTextDialog(
                'Open Source Licenses',
                'SurSathi in open-source packages ka use karta hai: Flutter, '
                'provider, just_audio, audio_service, youtube_explode_dart, '
                'sqflite, google_fonts, aur others — sab apne apne '
                'licenses (mostly MIT/BSD/Apache 2.0) ke under.',
              ),
            ),
            _buildInfoTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              onTap: () => _showTextDialog(
                'Privacy Policy',
                'SurSathi koi account nahi banata aur koi personal data '
                'server pe nahi bhejta.\n\n'
                'Sab kuch (liked songs, playlists, downloads, cache, '
                'settings) sirf aapke phone pe local store hota hai.\n\n'
                'Gaane play karne ke liye YouTube se stream kiya jaata hai.\n\n'
                'App uninstall karne pe saara local data khud hi delete '
                'ho jaata hai.\n\n'
                'Koi third-party analytics/ads SDK use nahi hoti.',
              ),
            ),
            _buildInfoTile(
              icon: Icons.gavel_outlined,
              title: 'Terms of Use',
              onTap: () => _showTextDialog(
                'Terms of Use',
                'SurSathi ek personal, non-commercial project hai.\n\n'
                'Ye app sirf shauk/educational purpose ke liye banaya gaya '
                'hai — koi commercial use ya redistribution allowed nahi hai.\n\n'
                'YouTube content ke rights unke respective owners ke paas '
                'hain; SurSathi sirf playback ke liye stream karta hai.',
              ),
            ),
            _buildInfoTile(
              icon: Icons.history,
              title: 'Version History',
              onTap: () => _showTextDialog(
                'Version History',
                'v1.0.0 — Initial release.',
              ),
            ),
            _buildInfoTile(
              icon: Icons.phone_android,
              title: 'Device',
              subtitle: _deviceLabel,
            ),

            const SizedBox(height: 24),
            Center(
              child: Text(
                '© 2024 SurSathi. Personal use only.',
                textAlign: TextAlign.center,
                style: AppText.bodyS().copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: kTextDim),
        title: Text(title, style: AppText.bodyL(color: kText)),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyS().copyWith(fontSize: 12),
              )
            : null,
        trailing: onTap != null
            ? const Icon(Icons.chevron_right, color: kTextDim, size: 20)
            : null,
        onTap: onTap,
      ),
    );
  }
}
