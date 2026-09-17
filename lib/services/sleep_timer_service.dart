// lib/services/sleep_timer_service.dart
// PART 2 (Sleep timer): global sleep-timer state.
//
// BUG FIX (2026-09-17): pehle FullPlayerScreen aur SettingsScreen dono ke
// apne-apne ALAG, screen-local `Timer? _sleepTimer` the (dono ek-dusre se
// bekhabar — settings_screen.dart me isi baat ka comment tha: "FullPlayerScreen
// ka bhi apna alag local timer hai, dono independent hain"). Isse do cheezein
// tooti thi:
//   1) Ek screen se sleep timer set karo, dusri screen pe uska koi pata hi
//      nahi chalta (icon on/off state mismatch).
//   2) Sabse bada: dono StatefulWidgets ka `dispose()` seedha
//      `_sleepTimer?.cancel()` karta tha — matlab sleep timer set karke
//      full player/settings screen band karte hi (jo normal usage hai —
//      "sleep timer laga ke phone lock kar do") timer SILENTLY cancel ho
//      jaata tha, gaana kabhi rukta hi nahi tha. User ko pata bhi nahi
//      chalta ki timer cancel ho gaya.
//
// Fix: ab sleep timer ka state yahan, ek global singleton (QueueService/
// LikeService jaisa hi `.instance` pattern) me rehta hai — `audioHandler`
// ki tarah poori app ki life tak zinda, kisi screen ke navigate/dispose
// hone se bilkul bekhabar.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'background_service.dart';

enum SleepTimerMode {
  off,
  duration, // fixed X minutes ke baad pause
  endOfTrack, // NEW (Part 2): "song khatam hone tak" — current gaana khatam hote hi pause
}

class SleepTimerService extends ChangeNotifier {
  SleepTimerService._internal();
  static final SleepTimerService instance = SleepTimerService._internal();

  SleepTimerMode _mode = SleepTimerMode.off;
  Timer? _timer;
  DateTime? _endsAt;
  Duration? _originalDuration;

  SleepTimerMode get mode => _mode;
  bool get isActive => _mode != SleepTimerMode.off;
  Duration? get originalDuration => _originalDuration;

  // Duration mode me kitna time bacha hai (UI me "12 min baad" jaisa
  // dikhane ke liye) — endOfTrack mode me null (koi fixed countdown nahi).
  Duration? get remaining {
    if (_mode != SleepTimerMode.duration || _endsAt == null) return null;
    final rem = _endsAt!.difference(DateTime.now());
    return rem.isNegative ? Duration.zero : rem;
  }

  void startDuration(Duration d) {
    _timer?.cancel();
    audioHandler.sleepAtEndOfTrack = false;
    _mode = SleepTimerMode.duration;
    _originalDuration = d;
    _endsAt = DateTime.now().add(d);
    _timer = Timer(d, _fireDuration);
    notifyListeners();
  }

  // NEW (Part 2): "Song khatam hone tak" — koi countdown Timer nahi, sirf
  // audioHandler ko batao ki jab current gaana `ProcessingState.completed`
  // ho, agle gaane pe skip karne ke bajaye bas pause kar do. Ye flag khud
  // audio handler (background_service.dart) me hi check hota hai, is
  // service ki UI screen se koi lena dena nahi — isliye 100% reliable hai
  // chahe user kahin bhi navigate kar jaaye.
  void startEndOfTrack() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    _originalDuration = null;
    _mode = SleepTimerMode.endOfTrack;
    audioHandler.sleepAtEndOfTrack = true;
    notifyListeners();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    _originalDuration = null;
    _mode = SleepTimerMode.off;
    audioHandler.sleepAtEndOfTrack = false;
    notifyListeners();
  }

  void _fireDuration() {
    audioHandler.pause();
    _timer = null;
    _endsAt = null;
    _originalDuration = null;
    _mode = SleepTimerMode.off;
    notifyListeners();
  }

  // background_service.dart current gaana khatam hone par (endOfTrack mode
  // me) khud hi pause kar chuka hota hai — ye sirf is service/UI ka state
  // reset karne ke liye call hota hai (icon wapas "off" dikhe).
  void notifyEndOfTrackFired() {
    if (_mode != SleepTimerMode.endOfTrack) return;
    _mode = SleepTimerMode.off;
    notifyListeners();
  }
}
