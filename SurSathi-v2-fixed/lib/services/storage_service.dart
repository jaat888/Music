// lib/services/storage_service.dart
// Static file/storage helpers — music folder, cache folder, size formatting.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class StorageService {
  StorageService._();

  // Permanent downloads yahan jaate hain — Music/SurSathi/
  // (public Music folder, taaki file manager / other apps me bhi dikhe)
  static Future<Directory> getMusicDir() async {
    const publicMusicPath = '/storage/emulated/0/Music/SurSathi';
    final dir = Directory(publicMusicPath);
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
