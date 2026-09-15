// lib/screens/help_screen.dart
// Help & FAQ — searchable expansion list + bug report link.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

const String _kGithubIssuesUrl = 'https://github.com/jaat888/SurSathi/issues';

class _FaqItem {
  final String question;
  final String answer;
  const _FaqItem(this.question, this.answer);
}

const List<_FaqItem> _kFaqs = [
  _FaqItem(
    'Gaana nahi chal raha?',
    'Internet check karo. Ya download karke offline suno. Agar YouTube ne '
        'block kiya ho to thodi der baad try karo.',
  ),
  _FaqItem(
    'Background me kaise chalayein?',
    "Settings → Background → 'Continue in background' ON karo. Battery "
        'optimization bhi off karo.',
  ),
  _FaqItem(
    'Cache kya hai?',
    'Auto-save songs for fast replay. Cache Manager me storage aur songs '
        'manage karo.',
  ),
  _FaqItem(
    'Download kahan jaata hai?',
    'Music/SurSathi/ folder me. File manager se access kar sakte ho.',
  ),
  _FaqItem(
    'Equalizer kaam nahi kar raha?',
    'Kuch phones pe DSP limited hai. Bass boost try karo. Real DSP future '
        'update me aayega.',
  ),
  _FaqItem(
    'YouTube URL expire?',
    'Auto-retry 3 baar hota hai. Dobara play karo.',
  ),
  _FaqItem(
    'Playlist share kaise?',
    'Playlist kholo → 3-dot menu → Share. Filhaal SnackBar dikhega.',
  ),
  _FaqItem(
    'Data kahan save hota hai?',
    'Sab local device pe. Koi server nahi. Koi account nahi.',
  ),
  _FaqItem(
    'Notification nahi aa rahi?',
    'Settings → Notifications → SurSathi ON karo. Do Not Disturb bhi '
        'check karo.',
  ),
  _FaqItem(
    'App crash ho rahi hai?',
    'App clear karo, dobara install. Agar phir bhi ho to GitHub pe report '
        'karo.',
  ),
];

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reportBug() async {
    final uri = Uri.parse(_kGithubIssuesUrl);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) throw Exception('launch failed');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied: $_kGithubIssuesUrl')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _kFaqs
        : _kFaqs
            .where((f) =>
                f.question.toLowerCase().contains(query) ||
                f.answer.toLowerCase().contains(query))
            .toList();

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Help & FAQ', style: AppText.displayM(color: kGreen).copyWith(fontSize: 24)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: kBgElev,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _searchController,
                  style: AppText.bodyL(color: kText),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Apna sawaal khoje...',
                    hintStyle: AppText.bodyM(),
                    prefixIcon: const Icon(Icons.search, color: kTextDim),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, color: kTextDim),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.search_off, color: kTextDim, size: 48),
                          const SizedBox(height: 10),
                          Text('Kuch nahi mila', style: AppText.bodyM(color: kTextDim)),
                        ],
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        ...filtered.map((faq) => Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: kBgElev,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Theme(
                                data: Theme.of(context).copyWith(
                                  dividerColor: Colors.transparent,
                                ),
                                child: ExpansionTile(
                                  iconColor: kGreen,
                                  collapsedIconColor: kTextDim,
                                  title: Text(
                                    faq.question,
                                    style: AppText.bodyL(color: kText).copyWith(fontSize: 14),
                                  ),
                                  childrenPadding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(faq.answer, style: AppText.bodyM()),
                                  ],
                                ),
                              ),
                            )),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                children: [
                  Text(
                    'Apna sawaal yahan nahi mila?',
                    style: AppText.bodyM().copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kGreen,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _reportBug,
                      icon: const Icon(Icons.bug_report, color: Colors.black),
                      label: Text('Report Bug', style: AppText.button(color: Colors.black)),
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
