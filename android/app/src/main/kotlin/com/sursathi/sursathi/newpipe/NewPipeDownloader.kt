package com.sursathi.sursathi.newpipe

import okhttp3.ConnectionSpec
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Downloader implementation for NewPipeExtractor — pure OkHttp, NO WebView.
 *
 * Batch-22-native (2026-09-16): pehle `newpipeextractor_dart` (Flutter
 * wrapper) apna signature-cipher `flutter_inappwebview` (WebView) ke
 * through solve karta tha, jo Android native View create karta tha aur
 * kuch specific videos pe native process-level crash karta tha — jo Dart
 * ke try/catch se pakad me nahi aata tha (dekho lib/services/
 * youtube_service.dart me is se pehle wale comments). Asli NewPipeExtractor
 * library khud WebView use nahi karti — signature-cipher Mozilla Rhino
 * (pure JVM JS interpreter, koi Android View nahi) se solve hoti hai —
 * isliye ye poori crash-class yahan exist hi nahi karti. Code niche
 * NewPipeExtractor ke apne quickstart docs (OkHttp DownloaderImpl example)
 * se liya gaya hai.
 */
class NewPipeDownloader private constructor() : Downloader() {

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        // Kuch services (jaise Bandcamp, NewPipeExtractor docs ke mutabik)
        // ko RESTRICTED_TLS chahiye — YouTube ke liye bhi harm nahi karta,
        // MODERN_TLS/COMPATIBLE_TLS fallback ke saath rakha hai taaki
        // purane Android version (minSdk 23) pe bhi handshake na tootey.
        .connectionSpecs(
            listOf(
                ConnectionSpec.RESTRICTED_TLS,
                ConnectionSpec.MODERN_TLS,
                ConnectionSpec.COMPATIBLE_TLS,
            )
        )
        .build()

    companion object {
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

        val instance: NewPipeDownloader by lazy { NewPipeDownloader() }
    }

    @Throws(IOException::class, ReCaptchaException::class)
    override fun execute(request: Request): Response {
        val httpMethod = request.httpMethod()
        val url = request.url()
        val headers = request.headers()
        val dataToSend = request.dataToSend()

        val requestBody = dataToSend?.toRequestBody(null)

        val requestBuilder = okhttp3.Request.Builder()
            .method(httpMethod, requestBody)
            .url(url)
            .addHeader("User-Agent", USER_AGENT)

        headers.forEach { (name, values) ->
            requestBuilder.removeHeader(name)
            values.forEach { value -> requestBuilder.addHeader(name, value) }
        }

        client.newCall(requestBuilder.build()).execute().use { response ->
            if (response.code == 429) {
                throw ReCaptchaException("reCaptcha Challenge requested", url)
            }

            var responseBodyToReturn: String? = null
            response.body?.use { body -> responseBodyToReturn = body.string() }

            return Response(
                response.code,
                response.message,
                response.headers.toMultimap(),
                responseBodyToReturn,
                response.request.url.toString(),
            )
        }
    }
}
