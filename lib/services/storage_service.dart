// lib/services/storage_service.dart
// Static file/storage helpers — music folder, cache folder, size formatting.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class StorageService {
  StorageService._();

  // Permanent downloads yahan jaate hain.
  //
  // FIX (see NOTES.md — "download nahi hota" root cause): pehle ye hamesha
  // hardcoded public path `/storage/emulated/0/Music/SurSathi` return karta
  // tha. Ye Android 10 tak `requestLegacyExternalStorage="true"` (manifest)
  // ki wajah se kaam karta tha, lekin us flag ko Android 11+ (API 30+)
  // *ignore* kar deta hai — scoped storage ke karan seedha arbitrary public
  // path pe likhna FileSystemException (permission denied) deta hai, chahe
  // `Permission.storage.request()` "granted" hi kyun na bole. Result: har
  // download silently fail hota tha (try/catch pakad leta tha, sirf generic
  // "Download fail ho gaya" SnackBar dikhta tha, real reason kabhi nazar
  // nahi aata tha) — asli app ka sabse bada "download nahi hota" bug yahi
  // tha.
  //
  // Fix: pehle public Music/SurSathi try karo (purane Android / jahan legacy
  // storage flag abhi bhi kaam karta hai, wahan file manager/other music
  // apps se bhi dikhegi) — ek chhota real write-test file se confirm karo
  // ki likha ja sakta hai. Fail ho to app-specific external storage
  // (`getExternalStorageDirectory()/Music`) pe fallback karo — ye kisi bhi
  // Android version pe BINA kisi permission ke hamesha likha ja sakta hai
  // (sirf is app ki apni jagah hai, isliye file manager ke "Music" folder
  // me nahi dikhegi — `Android/data/<package>/files/Music` me milegi —
  // lekin Downloads screen (in-app) hamesha sahi dikhayegi kyunki wo
  // `DownloadDB` se aata hai, disk path se nahi).
  static Future<Directory> getMusicDir() async {
    try {
      const publicMusicPath = '/storage/emulated/0/Music/SurSathi';
      final publicDir = Directory(publicMusicPath);
      if (!await publicDir.exists()) {
        await publicDir.create(recursive: true);
      }
      // Sirf create() se pata nahi chalta ki likhna bhi allowed hai —
      // scoped storage pe create() kabhi-kabhi pass ho jaata hai lekin
      // andar file likhna fail hota hai. Isliye ek chhota real write karo.
      final probe = File(p.join(publicDir.path, '.sursathi_write_test'));
      await probe.writeAsBytes(const [0]);
      await probe.delete();
      return publicDir;
    } catch (e) {
      print(
        'StorageService.getMusicDir: public Music folder likhi nahi ja '
        'saki ($e) — app-specific folder pe fallback kar rahe hain',
      );
    }

    final base = await getExternalStorageDirectory();
    final dir = Directory(
      p.join((base ?? await getApplicationDocumentsDirectory()).path, 'Music'),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // Temporary cache files yahan — app uninstall/clear cache pe apne aap saaf ho jaata hai
  static Future<Directory> getCacheDir() async {
    final baseDir = await getTemporaryDirectory();
    final dir = Directory('${baseDir.path}/sursathi_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // File name se invalid characters hatao (song title se file banani ho to)
  static Future<String> sanitizeFileName(String name) async {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'untitled' : cleaned;
  }

  // Free space check — abhi platform-specific disk-space plugin (jaise
  // disk_space/storage_info_plus) available nahi hai deps me, isliye
  // real value nahi mil sakta. -1 return karte hain "unknown" ke liye,
  // taaki UI graceful fallback dikha sake. Future batch me plugin add
  // karke isko replace kar sakte hain.
  static Future<int> getFreeSpaceBytes() async {
    return -1;
  }

  // Bytes ko readable string me convert karo — "2.1 GB" type
  static Future<String> formatBytes(int bytes) async {
    if (bytes < 0) return 'Unknown';
    if (bytes < 1024) return '$bytes B';

    const units = ['KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    var unitIndex = -1;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }
}
