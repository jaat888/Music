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

# Rhino ka optimizer (org.mozilla.javascript.optimizer.Bootstrapper waghera)
# JDK 9+ ke jdk.dynalink.* invokedynamic-linking classes ko reference karta
# hai (java.lang.invoke.CallSite bootstrap ke liye) — ye desktop-JDK-only
# classes Android/ART pe exist hi nahi karte, aur bytecode-generation wala
# ye optimizer code-path NewPipeExtractor me chalta bhi nahi. Isliye
# java.beans.** ki tarah hi, R8 ko in missing classes pe safely warn/fail
# mat karne do.
-dontwarn jdk.dynalink.**

# Rhino ka optional JSR-223 (javax.script) wrapper — RhinoScriptEngine,
# RhinoCompiledScript, RhinoScriptEngineFactory — javax.script.* classes ko
# reference karta hai. Ye JSR-223 API Android/ART me exist nahi karta, aur
# NewPipeExtractor is wrapper ko actually use nahi karta (sirf core Rhino
# interpreter use hota hai). Isliye R8 build fail ("Missing classes
# detected while running R8") na kare, is liye in classes ko dontwarn karo.
-dontwarn javax.script.**
