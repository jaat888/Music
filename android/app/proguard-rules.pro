# --- NewPipeExtractor (2026-09-16) ---
# Ye rules seedha NewPipeExtractor ke apne README se hain
# (https://github.com/TeamNewPipe/NewPipeExtractor) — "If you are using
# tools to minimize your project, make sure to keep the files below".
# In ke bina R8 minify (:app:minifyReleaseWithR8) fail hota hai.
-keep class org.schabi.newpipe.extractor.timeago.patterns.** { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.classfile.ClassFileWriter
-dontwarn org.mozilla.javascript.tools.**

# Rhino (org.mozilla.javascript) ke andar optional Java Bean introspection
# support (java.beans.*) reference hota hai (JavaToJSONConverters), lekin
# java.beans package Android runtime pe exist hi nahi karta aur
# NewPipeExtractor ke actual usage me ye code-path chalta bhi nahi. Isliye
# R8 ko ye missing classes safely ignore karne do, warn/fail mat karo.
-dontwarn java.beans.**
