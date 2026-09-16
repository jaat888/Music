// lib/services/app_logger.dart
//
// PURPOSE: user ne maanga tha ki sirf native crash log (CrashLogger.kt —
// jo sirf uncaught native crash pakadta hai) ke bajaye, POORE APP KA LOG
// (har print()/debugPrint() call, har Flutter framework error, har uncaught
// Dart exception) ek hi file me jama ho — taaki debug karte waqt sirf crash
// ka moment nahi, uske PEHLE ka pura context (kaunsa step chal raha tha,
// kaunsa API call fail hua, etc.) bhi mile.
//
// Isse achieve karne ke liye main.dart me poori app ko ek custom Zone
// (`runZonedGuarded`) ke andar run kiya gaya hai jiska `print` handler
// override hai — is wajah se codebase me jo bhi ~60+ `print(...)` calls
// already bikhre pade hain (youtube_service.dart, background_service.dart,
// etc.) unme se EK bhi line change kiye bina, sab automatically yahan
// capture ho jaate hain. `debugPrint` bhi andar se `print` hi call karta
// hai, isliye wo bhi cover ho jaata hai.
//
// Is file ka data CrashLogger.kt (native) se ALAG file me jaata hai —
// dono independent hain: crash log sirf native/Kotlin-side uncaught crash
// ke liye hai (process marne se pehle ka aakhri record, guaranteed likha
// jaata hai chahe Dart engine hi mar jaye), ye AppLogger poore app ke
// normal-se-normal se lekar error-level tak sab logs ke liye hai.

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const String _fileName = 'sursathi_app_log.txt';

  // File bahut bada na ho jaaye (purana data hataana padega) — 2 MB cap,
  // usse upar jaate hi purana aadha hissa trim kar dete hain.
  static const int _maxFileBytes = 2 * 1024 * 1024;

  File? _file;
  IOSink? _sink;

  // Init hone se pehle (ya file-write fail hone par) aaye logs yahan
  // temporarily rakhte hain — kho nahi jaate.
  final List<String> _pending = [];
  static const int _pendingCap = 300;

  // Debug screen me turant dikhane ke liye chhota in-memory buffer —
  // poori file disk se baar-baar padhne ki zaroorat nahi.
  final List<String> _memoryBuffer = [];
  static const int _memoryBufferCap = 500;

  bool _initializing = false;
  bool get isReady => _sink != null;

  Future<void> init() async {
    if (_sink != null || _initializing) return;
    _initializing = true;
    try {
      Directory? dir;
      try {
        // External files dir — CrashLogger.kt (getExternalFilesDir) jaisi
        // hi jagah, koi runtime permission nahi chahiye.
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      dir ??= await getApplicationDocumentsDirectory();

      _file = File('${dir.path}/$_fileName');
      await _trimIfTooBig();
      _sink = _file!.openWrite(mode: FileMode.append);

      log('===== APP START ${DateTime.now()} =====');
      for (final line in _pending) {
        _sink?.writeln(line);
      }
      _pending.clear();
    } catch (e) {
      // Logger khud kabhi crash na kare / app ko block na kare — agar
      // init fail ho to bhi in-memory buffer + _pending list se log kaam
      // karta rehta hai, bas disk pe save nahi hoga.
    } finally {
      _initializing = false;
    }
  }

  Future<void> _trimIfTooBig() async {
    final f = _file;
    if (f == null || !await f.exists()) return;
    try {
      final len = await f.length();
      if (len <= _maxFileBytes) return;
      final content = await f.readAsString();
      final halfCap = _maxFileBytes ~/ 2;
      final keep = content.length > halfCap
          ? content.substring(content.length - halfCap)
          : content;
      await f.writeAsString(
        '...[purana log yahan trim ho gaya, file size control ke liye]...\n'
        '$keep',
      );
    } catch (_) {
      // Trim fail ho to bhi aage badhte hain — sirf file bada rahega.
    }
  }

  /// Ek line log karo. Normal app code isse direct call kar sakta hai
  /// (`AppLogger.instance.log('...')`), lekin zyaadatar existing
  /// `print()`/`debugPrint()` calls automatically yahan pahunchte hain
  /// (dekho main.dart ka ZoneSpecification.print override) — unhe badalne
  /// ki zaroorat nahi.
  void log(String message, {String level = 'INFO'}) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts][$level] $message';

    _memoryBuffer.add(line);
    if (_memoryBuffer.length > _memoryBufferCap) {
      _memoryBuffer.removeAt(0);
    }

    final sink = _sink;
    if (sink != null) {
      try {
        sink.writeln(line);
      } catch (_) {
        // write fail — silently ignore, logger khud crash na kare
      }
    } else {
      _pending.add(line);
      if (_pending.length > _pendingCap) {
        _pending.removeAt(0);
      }
    }
  }

  void logError(String context, Object error, StackTrace? stack) {
    log('$context: $error${stack != null ? '\n$stack' : ''}', level: 'ERROR');
  }

  /// Debug screen me turant preview dikhane ke liye — disk read ki
  /// zaroorat nahi.
  List<String> get recentLines => List.unmodifiable(_memoryBuffer);

  String? get filePath => _file?.path;

  Future<String?> readFullLog() async {
    try {
      await _sink?.flush();
      final f = _file;
      if (f != null && await f.exists()) {
        return await f.readAsString();
      }
    } catch (_) {}
    // File abhi tak ready nahi hui / read fail hua — kam se kam jo
    // memory me hai wo to dikha dete hain.
    return _memoryBuffer.isEmpty ? null : _memoryBuffer.join('\n');
  }

  Future<void> clear() async {
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      final f = _file;
      if (f != null && await f.exists()) {
        await f.delete();
      }
      _memoryBuffer.clear();
      if (f != null) {
        _sink = f.openWrite(mode: FileMode.append);
        log('===== LOG CLEARED ${DateTime.now()} =====');
      }
    } catch (_) {}
  }

  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }
}
