// lib/screens/permission_screen.dart
// Storage / Notification / Microphone permissions maangte hain. "Allow All"
// se sab ek saath request hoti hain, har card apna status badge dikhata hai.

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'taste_screen.dart';

enum _PermState { notAsked, granted, denied }

class _PermItem {
  final Permission permission;
  final IconData icon;
  final String title;
  final String desc;
  _PermState state;

  _PermItem({
    required this.permission,
    required this.icon,
    required this.title,
    required this.desc,
    this.state = _PermState.notAsked,
  });
}

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  final List<_PermItem> _items = [
    _PermItem(
      permission: Permission.storage,
      icon: Icons.storage,
      title: 'Storage',
      desc: 'Music save karne ke liye',
    ),
    _PermItem(
      permission: Permission.notification,
      icon: Icons.notifications,
      title: 'Notification',
      desc: 'Now playing controls ke liye',
    ),
    _PermItem(
      permission: Permission.microphone,
      icon: Icons.mic,
      title: 'Microphone',
      desc: 'Voice search (optional)',
    ),
  ];

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatuses();
  }

  // App khulte hi current status check karo (agar pehle se granted hai)
  Future<void> _loadStatuses() async {
    for (final item in _items) {
      final status = await item.permission.status;
      item.state =
          status.isGranted ? _PermState.granted : _PermState.notAsked;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _allowAll() async {
    final statuses = await [
      Permission.storage,
      Permission.notification,
      Permission.microphone,
    ].request();

    for (final item in _items) {
      final status = statuses[item.permission];
      if (status != null) {
        item.state = status.isGranted ? _PermState.granted : _PermState.denied;
      }
    }
    if (mounted) setState(() {});
  }

  void _goNext() {
    Navigator.of(context).pushReplacement(_fadeSlideRoute());
  }

  Route _fadeSlideRoute() {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      pageBuilder: (_, __, ___) => const TasteScreen(),
      transitionsBuilder: (_, anim, __, child) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        );
      },
    );
  }

  Color _badgeColor(_PermState state) {
    switch (state) {
      case _PermState.granted:
        return kGreen;
      case _PermState.denied:
        return kRed;
      case _PermState.notAsked:
        return kTextDim;
    }
  }

  String _badgeLabel(_PermState state) {
    switch (state) {
      case _PermState.granted:
        return 'Granted';
      case _PermState.denied:
        return 'Denied';
      case _PermState.notAsked:
        return 'Not asked';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Permissions', style: AppText.displayM()),
                  TextButton(
                    onPressed: _goNext,
                    child: Text('Skip', style: AppText.button(color: kTextDim)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Best experience ke liye ye allow karo',
                style: AppText.bodyM(),
              ),
              const SizedBox(height: 24),
              if (_loading)
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(color: kGreen),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: kBgElev,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Icon(item.icon, color: kGreen, size: 28),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    style: AppText.bodyL()
                                        .copyWith(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(item.desc, style: AppText.bodyS()),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: _badgeColor(item.state).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                _badgeLabel(item.state),
                                style: AppText.label(
                                  color: _badgeColor(item.state),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: kGreen, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: _allowAll,
                  child: Text('Allow All', style: AppText.button(color: kGreen)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGreen,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: _goNext,
                  child: Text('Next', style: AppText.button()),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
