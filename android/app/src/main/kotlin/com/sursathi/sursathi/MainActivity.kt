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
    }
}
