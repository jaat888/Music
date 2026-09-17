package com.sursathi.sursathi.newpipe

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.exceptions.AgeRestrictedContentException
import org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException
import org.schabi.newpipe.extractor.exceptions.ExtractionException
import org.schabi.newpipe.extractor.exceptions.GeographicRestrictionException
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.VideoStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Handler for MethodChannel "com.sursathi.sursathi/newpipe".
 *
 * Batch-22-native (2026-09-16, Option C): `newpipeextractor_dart` (WebView-
 * based Flutter wrapper) ki jagah — asli NewPipeExtractor Java library ko
 * yahan seedha (Kotlin se) call karte hain, bilkul OuterTune/OpenTune jaisa,
 * koi wrapper-plugin beech me nahi. Dart-side (youtube_service.dart) ka
 * purana `_newPipeLock` mutex (WebView-instance-limit crash rokne ke liye
 * tha) yahan jaanbujhke NAHI dohraya gaya — NewPipeExtractor khud asli
 * NewPipe app me bhi parallel/concurrent use hoti hai (thread-safe hai,
 * har extraction apna khud ka Rhino JS Context banata hai), isliye
 * `executor` (cachedThreadPool) pe multiple calls bina kisi lock ke parallel
 * chal sakti hain.
 */
object NewPipeAudioChannel {
    const val CHANNEL_NAME = "com.sursathi.sursathi/newpipe"

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var initialized = false

    private fun ensureInit() {
        if (initialized) return
        synchronized(this) {
            if (!initialized) {
                NewPipe.init(NewPipeDownloader.instance)
                initialized = true
            }
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAudioStream" -> {
                val videoId = call.argument<String>("videoId")
                if (videoId.isNullOrBlank()) {
                    result.error("BAD_ARGS", "videoId missing", null)
                    return
                }
                // PART 1 (audio quality toggle): Dart-side ab "low"/"med"/
                // "high" bhejta hai (settings_screen.dart ke Audio/Download
                // Quality dialog se, wahi value jo streaming ya download ke
                // liye chuni gayi hai). Missing/unknown -> "high" (purana
                // behavior, sabse zyada bitrate) taaki backward-compatible
                // rahe agar kisi purani Dart build se bina is arg ke call
                // aa jaaye.
                val quality = (call.argument<String>("quality") ?: "high").lowercase()
                executor.execute { resolveAudioStream(videoId, quality, result) }
            }
            else -> result.notImplemented()
        }
    }

    private fun resolveAudioStream(videoId: String, quality: String, result: MethodChannel.Result) {
        try {
            ensureInit()
            val url = "https://www.youtube.com/watch?v=$videoId"
            val info: StreamInfo = StreamInfo.getInfo(ServiceList.YouTube, url)

            val audioStreams: List<AudioStream> = info.audioStreams ?: emptyList()
            val playable = audioStreams.filter { !it.content.isNullOrEmpty() }
            // PART 1 (data saver): "low" = sabse kam bitrate (kam data use,
            // kharaab-ish quality) — "med" = beech wala bitrate — "high"
            // (default, purana behavior) = sabse best bitrate. Agar list
            // khaali hai to null hi rahega (neeche muxed fallback try hoga,
            // jaisa pehle hota tha).
            val sortedByBitrateAsc = playable.sortedBy { it.averageBitrate }
            val best = when (quality) {
                "low" -> sortedByBitrateAsc.firstOrNull()
                "med", "medium" -> sortedByBitrateAsc.getOrNull(sortedByBitrateAsc.size / 2)
                else -> sortedByBitrateAsc.lastOrNull()
            }

            val map = HashMap<String, Any?>()
            map["title"] = info.name
            map["author"] = info.uploaderName
            map["duration"] = info.duration
            map["thumb"] = info.thumbnails?.lastOrNull()?.url

            if (best != null) {
                map["url"] = best.content
                map["format"] = best.format?.suffix ?: "m4a"
                map["bitrate"] = best.averageBitrate
                map["kind"] = "audio"
                mainOk(result, map)
                return
            }

            // Audio-only nahi mila — muxed (video+audio) fallback, jaise
            // Dart-side pehle karta tha (dekho youtube_service.dart
            // _audioViaNewPipe).
            val videoStreams: List<VideoStream> = info.videoStreams ?: emptyList()
            val playableMuxed = videoStreams.filter { !it.content.isNullOrEmpty() }
            // Muxed streams me audio-only jitni clean bitrate field nahi
            // milti (NewPipe API version ke hisaab se alag ho sakti hai),
            // isliye yahan safe rehte hain: "low" quality me list ka AAKHRI
            // wala try karo (NewPipe generally best-pehle order deta hai,
            // isliye last = usually sabse chhota/halka), warna (high/med)
            // pehla wala — jaisa pehle hota tha.
            val muxed = if (quality == "low") {
                playableMuxed.lastOrNull() ?: playableMuxed.firstOrNull()
            } else {
                playableMuxed.firstOrNull()
            }
            if (muxed != null) {
                map["url"] = muxed.content
                map["format"] = muxed.format?.suffix ?: "mp4"
                map["bitrate"] = 0
                map["kind"] = "muxed"
                mainOk(result, map)
                return
            }

            mainErr(result, "NO_STREAM", "NewPipeExtractor: koi audio ya muxed stream nahi mila", null)
        } catch (e: ContentNotAvailableException) {
            mainErr(result, "NOT_AVAILABLE", "Content not available: ${e.message}", null)
        } catch (e: GeographicRestrictionException) {
            mainErr(result, "GEO_BLOCKED", "Region blocked: ${e.message}", null)
        } catch (e: AgeRestrictedContentException) {
            mainErr(result, "AGE_RESTRICTED", "Age-restricted: ${e.message}", null)
        } catch (e: ReCaptchaException) {
            mainErr(result, "RECAPTCHA", "Rate limited / CAPTCHA: ${e.message}", null)
        } catch (e: ExtractionException) {
            mainErr(result, "EXTRACTION_FAILED", "Extraction failed: ${e.message}", null)
        } catch (e: IOException) {
            mainErr(result, "NETWORK_ERROR", "Network error: ${e.message}", null)
        } catch (e: Throwable) {
            // `Throwable` jaanbujhke (na ki sirf `Exception`) — R8/ProGuard
            // release build me `org.schabi.newpipe.extractor.**` ke andar
            // kisi class/method ko obfuscate/strip kar sakta hai (proguard-
            // rules.pro me sirf timeago.patterns + Rhino ke liye keep rules
            // hain, poore extractor package ke liye nahi). Aisa hone par
            // runtime pe `NoSuchMethodError`/`NoClassDefFoundError` jaisi
            // `Error` aati hai — `Exception` isse pakadta NAHI, aur wo
            // seedha process crash kar deta, bilkul usi purani WebView-crash
            // class ki tarah jo Dart try/catch se bhi nahi pakdi jaati thi.
            mainErr(result, "UNKNOWN", "Unexpected: ${e.message}", null)
        }
    }

    private fun mainOk(result: MethodChannel.Result, map: Map<String, Any?>) {
        mainHandler.post { result.success(map) }
    }

    private fun mainErr(result: MethodChannel.Result, code: String, message: String, details: Any?) {
        mainHandler.post { result.error(code, message, details) }
    }
}
