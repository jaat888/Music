// lib/services/audio_focus_service.dart
// Phone call, doosra app audio, headphone unplug — in sab situations me
// player ko sahi se pause/duck/resume karwata hai.

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

class AudioFocusService {
  AudioFocusService._();

  static AudioSession? _session;
  static StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  static StreamSubscription<void>? _noisySub;

  // Ek baar app start pe call karo — callbacks background_service se aayenge
  static Future<void> configure({
    required VoidCallback onCallPause,
    required VoidCallback onCallResume,
    required void Function(bool duck) onDuck,
    required VoidCallback onHeadphoneUnplug,
  }) async {
    _session = await AudioSession.instance;
    await _session!.configure(const AudioSessionConfiguration.music());

    // Interruption events: phone call aana, doosra app music play karna, etc.
    _interruptionSub = _session!.interruptionEventStream.listen((event) {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            // Notification/short sound — volume kam karo, ruko mat
            onDuck(true);
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            // Call aaya ya doosra app takeover — pause karo
            onCallPause();
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            onDuck(false);
            break;
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            // Interruption khatam — resume ka option do (auto-resume nahi,
            // user decide kare kyunki kabhi kabhi call ke baad play nahi
            // karna chahte)
            onCallResume();
            break;
        }
      }
    });

    // Headphone nikalne pe (becoming noisy) — turant pause taaki speaker
    // pe achanak loud na baje
    _noisySub = _session!.becomingNoisyEventStream.listen((_) {
      onHeadphoneUnplug();
    });
  }

  static Future<void> dispose() async {
    await _interruptionSub?.cancel();
    await _noisySub?.cancel();
  }
}
