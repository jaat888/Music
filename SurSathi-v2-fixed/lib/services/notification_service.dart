// lib/services/notification_service.dart
// Extra notifications ke liye — download complete, new release, etc.
// NOTE: Actual media playback notification (play/pause/next controls)
// audio_service khud handle karta hai — ye service us se alag hai.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  static const String audioChannelId = 'sursathi_audio';
  static const String generalChannelId = 'sursathi_general';
  static const int _nowPlayingId = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(initSettings);

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // Audio channel — high importance (playback se related updates)
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        audioChannelId,
        'SurSathi Playback',
        description: 'Playback se related notifications',
        importance: Importance.high,
      ),
    );

    // General channel — downloads, updates, wagaira
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        generalChannelId,
        'SurSathi Updates',
        description: 'Downloads aur general app notifications',
        importance: Importance.defaultImportance,
      ),
    );

    _initialized = true;
  }

  // Extra "now playing" style info notification (media controls wali nahi —
  // wo audio_service khud dikhata hai)
  Future<void> showNowPlaying({
    required String title,
    required String artist,
    String? thumb,
    bool isPlaying = true,
  }) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      audioChannelId,
      'SurSathi Playback',
      channelDescription: 'Playback se related notifications',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
      onlyAlertOnce: true,
      playSound: false,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _nowPlayingId,
      title,
      artist,
      details,
    );
  }

  Future<void> cancelNowPlaying() async {
    await _plugin.cancel(_nowPlayingId);
  }

  // Simple one-off notification — download complete, error, etc.
  Future<void> showGeneral({
    required String title,
    required String body,
  }) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      generalChannelId,
      'SurSathi Updates',
      channelDescription: 'Downloads aur general app notifications',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      details,
    );
  }
}
