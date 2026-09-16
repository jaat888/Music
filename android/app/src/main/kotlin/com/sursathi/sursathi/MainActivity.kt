package com.sursathi.sursathi

import com.ryanheise.audioservice.AudioServiceActivity
import com.sursathi.sursathi.newpipe.NewPipeAudioChannel
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service ko background playback + notification/lock-screen controls
// ke liye MainActivity ko AudioServiceActivity extend karna zaroori hai.
// Iske bina AudioService.init() fail hota hai aur runApp() kabhi call hi
// nahi hota — yahi white-screen ka asli root cause tha.
class MainActivity : AudioServiceActivity() {

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
    }
}
