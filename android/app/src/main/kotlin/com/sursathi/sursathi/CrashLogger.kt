package com.sursathi.sursathi

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Post-Batch-22 addition (2026-09-16): user ke paas PC/adb nahi hai aur
 * MIUI ka Developer-options "Bug report" tool bhi is device/ROM pe missing
 * hai, isliye crash debug karne ka koi tarika nahi tha. Ye object app ka
 * apna crash log leta hai — bina PC, bina root, bina logcat ke:
 *
 * `Thread.setDefaultUncaughtExceptionHandler` poore app ke liye EK hi baar
 * global hota hai — jo bhi uncaught Throwable (Exception YA Error, dono)
 * kahin bhi (Dart-side nahi, native Kotlin/Java side) crash karta hai, wo
 * yahan se guzarta hai isse pehle ki process mare. Hum poora stack trace
 * ek text file me likh dete hain (app-specific external storage — koi
 * runtime permission nahi chahiye, Android 10+ scoped storage compliant),
 * phir purane/system default handler ko call karte hain taaki normal
 * "App has stopped" crash-dialog/process-death behaviour waisa hi rahe
 * jaisa install na karne par hota.
 *
 * Agli baar app khulne par Debug screen se is file ko seedha share_plus se
 * WhatsApp/Telegram/Files pe share kiya ja sakta hai (dekho debug_screen.dart
 * ka "Crash Log" section) — MethodChannel "com.sursathi.sursathi/crashlog"
 * (MainActivity.kt) exact path deta hai.
 */
object CrashLogger {
    private const val FILE_NAME = "sursathi_crash_log.txt"

    fun install(context: Context) {
        val appContext = context.applicationContext
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrash(appContext, thread, throwable)
            } catch (_: Throwable) {
                // Crash-logger khud kabhi crash na kare (warna original
                // crash ki jagah isi ka silent failure reh jaata) —
                // jaanbujhke poori tarah swallow kiya gaya hai.
            }
            // Purana/system default handler ko call karna ZAROORI hai —
            // isse skip karne par process hang ho sakta hai ya Android ka
            // normal "App has stopped" flow break ho sakta hai.
            previousHandler?.uncaughtException(thread, throwable)
        }
    }

    private fun writeCrash(context: Context, thread: Thread, throwable: Throwable) {
        val sw = StringWriter()
        throwable.printStackTrace(PrintWriter(sw))
        val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        val entry = buildString {
            append("===== CRASH $timestamp (thread: ${thread.name}) =====\n")
            append(sw.toString())
            append("\n\n")
        }
        // appendText naya file bana deta hai agar exist nahi karti — purane
        // crashes bhi is file me neeche jama rehte hain (multi-crash history
        // ek hi file me, jab tak Debug screen se clear na kiya jaaye).
        File(logDir(context), FILE_NAME).appendText(entry)
    }

    private fun logDir(context: Context): File {
        // getExternalFilesDir(null) = /storage/emulated/0/Android/data/
        // com.sursathi.sursathi/files — app-uninstall pe apne aap clean
        // hoti hai, koi WRITE_EXTERNAL_STORAGE permission nahi chahiye.
        // Kabhi-kabhar (SD card unmounted jaisi edge-case) null aa sakta
        // hai, tab internal filesDir pe fallback (share karne ke liye bhi
        // kaam karta hai, bas file-manager se directly browse nahi hoti).
        return context.getExternalFilesDir(null) ?: context.filesDir
    }

    fun logFilePath(context: Context): String {
        return File(logDir(context), FILE_NAME).absolutePath
    }

    fun clear(context: Context) {
        val f = File(logDir(context), FILE_NAME)
        if (f.exists()) f.delete()
    }
}
