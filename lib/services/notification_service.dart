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

  // NEW (v37 — "download waale mein kaunsa download ho raha hai, kaunsa
  // queue mein hai kabhi nahi dikhta"): ek hi persistent progress
  // notification (fixed id) — jo currently-downloading song ka naam +
  // % progress dikhaye, aur agar aur gaane queue mein bache hain to
  // "N aur gaane queue mein" bhi. DownloadQueueService ise har progress
  // tick pe update karta hai.
  static const int _downloadProgressId = 1002;

  Future<void> showDownloadProgress({
    required String songTitle,
    required int progressPercent, // 0-100
    required int queuedCount,
  }) async {
    if (!_initialized) await init();

    final body = queuedCount > 0
        ? '$progressPercent% • $queuedCount aur gaane queue mein baaki'
        : '$progressPercent%';

    final androidDetails = AndroidNotificationDetails(
      generalChannelId,
      'SurSathi Updates',
      channelDescription: 'Downloads aur general app notifications',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      onlyAlertOnce: true,
      playSound: false,
      showProgress: true,
      maxProgress: 100,
      progress: progressPercent.clamp(0, 100).toInt(),
      // progressPercent 0 hone par bhi (stream ka contentLength na mile
      // to hota hai) ek indeterminate bar dikhao, "kuch nahi ho raha"
      // jaisa na lage.
      indeterminate: progressPercent <= 0,
    );
    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      _downloadProgressId,
      'Download ho raha hai: $songTitle',
      body,
      details,
    );
  }

  Future<void> cancelDownloadProgress() async {
    await _plugin.cancel(_downloadProgressId);
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
