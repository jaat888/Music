package com.sursathi.sursathi

import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import com.sursathi.sursathi.newpipe.NewPipeAudioChannel
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service ko background playback + notification/lock-screen controls
// ke liye MainActivity ko AudioServiceActivity extend karna zaroori hai.
// Iske bina AudioService.init() fail hota hai aur runApp() kabhi call hi
// nahi hota — yahi white-screen ka asli root cause tha.
class MainActivity : AudioServiceActivity() {

    // Post-Batch-22 (PC/logcat na hone ki wajah se): sabse pehli line me hi
    // global crash-catcher install — taaki startup ke bilkul shuru me bhi
    // (Flutter engine banne se pehle) koi native crash aaye to bhi pakda
    // jaaye. Dekho CrashLogger.kt.
    override fun onCreate(savedInstanceState: Bundle?) {
        CrashLogger.install(this)
        super.onCreate(savedInstanceState)
    }

    // Batch-22-native (2026-09-16, Option C): NewPipeExtractor (audio-fetch
    // ke liye) ko seedha native Kotlin se call karne wala MethodChannel —
    // dekho android/app/src/main/kotlin/com/sursathi/sursathi/newpipe/
    // (NewPipeDownloader.kt, NewPipeAudioChannel.kt) aur Dart side
    // lib/services/youtube_service.dart (_audioViaNewPipe).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NewPipeAudioChannel.CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            NewPipeAudioChannel.handle(call, result)
        }

        // Post-Batch-22: crash log path Dart ko dene ke liye — Debug screen
        // ka "Crash Log" section isse read/share karta hai (dekho
        // CrashLogger.kt, lib/screens/debug_screen.dart).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.sursathi.sursathi/crashlog",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPath" -> result.success(CrashLogger.logFilePath(this))
                "clear" -> {
                    CrashLogger.clear(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // BUG FIX (2026-09-18, v59 — "Radio me back dabane se app
        // force-stop jaisa exit ho jaata hai, minimize nahi hota"): jab
        // Flutter Navigator ke paas pop karne ko kuch nahi bachta,
        // Flutter/Android ka DEFAULT back-button behavior activity ko
        // `finish()` kar deta hai — normal "Home button dabao to app
        // background me chala jaaye" wala minimize nahi hota, poora
        // task/activity hi tut jaata hai (foreground service/notification
        // ke liye ye bilkul "app crash ho gaya" jaisa mehsoos hota hai).
        // `moveTaskToBack(true)` iske bajaye sirf task ko background me
        // bhej deta hai — activity zinda rehti hai, playback/notification
        // bina rukawat chalte rehte hain, jaise koi bhi normal Android app
        // Home button se karta hai. lib/screens/radio_player_screen.dart
        // ka `WillPopScope` phone ke back button (hardware/gesture) par
        // isi method ko call karta hai — screen ka apna × (close) button
        // isse bilkul alag/unaffected rehta hai, seedha Navigator.pop()
        // use karta hai jaise pehle karta tha.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.sursathi.sursathi/nav",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
