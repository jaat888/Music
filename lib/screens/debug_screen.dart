// lib/screens/debug_screen.dart
// Debug screen — YouTube search/stream fail kyun ho raha, ye pata karne ke
// liye. Production feature nahi hai, sirf troubleshooting tool.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:share_plus/share_plus.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../services/youtube_service.dart';
import '../db/app_database.dart';

// BUILD MARKER — is text ko yahan se badal ke naya zip banaya jaata hai.
// Debug screen (🐛 icon) khol ke agar ye wahi text dikhe jo abhi aapko
// bheja gaya hai, to confirm ho jaata hai ki NAYA code hi build/run ho
// raha hai. Agar purana marker dikhe (ya ye poori section hi missing ho),
// to matlab build abhi bhi purane source se ban raha hai.
const String kBuildMarker = 'NEWPIPE-NATIVE-2026-09-16-v10';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  bool _searching = false;
  bool _testingAudio = false;
  bool _testingDirect = false;

  String? _searchSummary;
  List<YtResult> _searchResults = [];
  String? _searchError;
  String? _searchProgress;

  String? _audioUrlResult;
  String? _audioUrlError;
  String? _audioUrlProgress;
  final List<String> _audioUrlLog = [];

  String? _directResult;
  String? _directError;

  // DB tables checker state
  bool _checkingDb = false;
  List<String>? _dbTables;
  String? _dbCheckError;

  // Crash log state (PC/logcat na hone par app-ke-andar-hi crash capture —
  // dekho android/.../CrashLogger.kt)
  static const MethodChannel _crashLogChannel =
      MethodChannel('com.sursathi.sursathi/crashlog');
  bool _loadingCrashLog = false;
  String? _crashLogStatus;
  String? _crashLogPreview;
  String? _crashLogPath;

  Future<void> _loadAndShareCrashLog() async {
    setState(() {
      _loadingCrashLog = true;
      _crashLogStatus = null;
      _crashLogPreview = null;
    });
    try {
      final path =
          await _crashLogChannel.invokeMethod<String>('getPath');
      if (path == null) {
        throw Exception('Native se path nahi mila');
      }
      _crashLogPath = path;
      final file = File(path);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _loadingCrashLog = false;
          _crashLogStatus = 'Koi crash log nahi mila — ya to app kabhi '
              'crash nahi hui, ya crash Dart-side thi (isse pakda gaya '
              'aur app chalti rahi, koi native process-crash nahi hua).';
        });
        return;
      }
      final content = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _loadingCrashLog = false;
        _crashLogPreview = content;
        _crashLogStatus = '${content.length} characters mile. Neeche '
            '"Share" se WhatsApp/Telegram/Files pe bhej sakte ho.';
      });
      // Turant share-sheet bhi khol do — user ko alag se button dhoondna
      // na pade.
      await Share.shareXFiles(
        [XFile(path)],
        text: 'SurSathi crash log',
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCrashLog = false;
        _crashLogStatus = 'Native error: ${e.code}: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCrashLog = false;
        _crashLogStatus = 'Error: $e';
      });
    }
  }

  Future<void> _shareCrashLogAgain() async {
    final path = _crashLogPath;
    if (path == null) return;
    await Share.shareXFiles([XFile(path)], text: 'SurSathi crash log');
  }

  Future<void> _clearCrashLog() async {
    try {
      await _crashLogChannel.invokeMethod('clear');
      if (!mounted) return;
      setState(() {
        _crashLogPreview = null;
        _crashLogPath = null;
        _crashLogStatus = 'Crash log clear kar diya gaya.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _crashLogStatus = 'Clear fail: $e');
    }
  }

  Future<void> _checkDbTables() async {
    setState(() {
      _checkingDb = true;
      _dbTables = null;
      _dbCheckError = null;
    });
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );
      if (!mounted) return;
      setState(() {
        _dbTables = rows.map((r) => r['name'] as String).toList();
        _checkingDb = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dbCheckError = e.toString();
        _checkingDb = false;
      });
    }
  }

  // Hardcoded test video id — koi bhi hamesha-available public video
  static const String _kTestVideoId = 'dQw4w9WgXcQ';

  Future<void> _testSearch() async {
    setState(() {
      _searching = true;
      _searchSummary = null;
      _searchResults = [];
      _searchError = null;
      _searchProgress = 'Starting...';
    });

    try {
      final results = await YoutubeService.instance.search(
        'arijit singh',
        onProgress: (status) {
          if (!mounted) return;
          setState(() => _searchProgress = status);
        },
      );
      if (!mounted) return;
      setState(() {
        _searchResults = results.take(5).toList();
        _searchSummary = results.isEmpty
            ? 'Search returned 0 results — saare public Piped instances '
                'fail ho gaye ya genuinely 0 mile, upar progress text me '
                'dekho kis instance pe kya hua'
            : '${results.length} results mile';
        _searching = false;
        _searchProgress = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
        _searching = false;
        _searchProgress = null;
      });
    }
  }

  Future<void> _testAudioUrl() async {
    // BUG FIX: pehle agar "Test Search" pehle na chalaya ho to ye button
    // sirf ek chhota red error dikha ke ruk jaata tha ("Pehle Test Search
    // chalao") — user ko lagta button hi kaam nahi kar raha. Ab search
    // results na ho to seedha hardcoded test video ($_kTestVideoId) use
    // kar lete hain, koi extra step nahi chahiye.
    final testResult = _searchResults.isNotEmpty ? _searchResults.first : null;
    final testId = testResult?.id ?? _kTestVideoId;

    setState(() {
      _testingAudio = true;
      _audioUrlResult = null;
      _audioUrlError = null;
      _audioUrlProgress = 'Starting...';
      _audioUrlLog.clear();
      _audioUrlLog.add('Starting...');
    });

    try {
      // BUG FIX: getAudioUrl() 5 clients try karta hai, har ek me
      // network timeout (10s) + CDN verify (~18s tak) ho sakta hai —
      // worst case ~2-2.5 minute tak koi visible progress nahi hota tha,
      // isliye lagta tha button "atak gaya" / kaam nahi kar raha. Ab
      // onProgress callback se har client ka live status dikhta hai, aur
      // poore call pe ek 3-minute hard timeout hai taaki genuinely stuck
      // na rahe.
      // BUG FIX 2: pehle sirf latest progress line dikhti thi aur test
      // khatam hote hi wo bhi clear ho jaati thi — beech ke saare steps
      // (kaunsa client try hua, kahan fail hua) gum ho jaate the, sirf
      // generic "URL FAIL" bachta tha jisse kuch pata nahi chalta tha.
      // Ab har step _audioUrlLog me accumulate hota hai aur test khatam
      // hone ke baad bhi dikhta rehta hai.
      // BUG FIX 3: title/author bhi pass karte hain (jaise Termux test
      // karta hai) — is se videoId-sanity-check self-heal actually chalta
      // hai yahan se bhi, na ki sirf standalone script me.
      final url = await YoutubeService.instance
          .getAudioUrl(
            testId,
            title: testResult?.title,
            author: testResult?.author,
            onProgress: (status) {
              if (!mounted) return;
              setState(() {
                _audioUrlProgress = status;
                _audioUrlLog.add(status);
              });
            },
          )
          .timeout(
            const Duration(minutes: 3),
            onTimeout: () {
              throw TimeoutException(
                '3 minute ho gaye, koi client respond nahi kar raha — '
                'internet check karo ya thodi der baad try karo',
              );
            },
          );
      if (!mounted) return;
      setState(() {
        _audioUrlResult = url == null
            ? 'URL FAIL — saare clients fail (ya to resolve nahi hua, ya '
                'resolve hone ke baad bhi CDN se real fetch fail hua — '
                'dono case cover hote hain ab)'
            : 'URL OK (real CDN fetch se bhi verify hua): '
                '${url.substring(0, url.length > 80 ? 80 : url.length)}...';
        _testingAudio = false;
        _audioUrlProgress = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _audioUrlError = e.toString();
        _testingAudio = false;
        _audioUrlProgress = null;
      });
    }
  }

  Future<void> _testDirectVideo() async {
    setState(() {
      _testingDirect = true;
      _directResult = null;
      _directError = null;
    });

    try {
      final url = await YoutubeService.instance.getAudioUrl(_kTestVideoId);
      if (!mounted) return;
      setState(() {
        _directResult = url == null
            ? 'URL FAIL — null aaya (saare clients fail) — hardcoded'
                ' video ($_kTestVideoId) pe bhi fail, matlab network/library'
                ' issue hai, specific video ka nahi'
            : 'URL OK: ${url.substring(0, url.length > 80 ? 80 : url.length)}...';
        _testingDirect = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _directError = e.toString();
        _testingDirect = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: Text('Debug — YouTube', style: AppText.displayM(color: kText)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- BUILD MARKER + DB TABLE CHECKER ---
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2333),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF3A4560)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Build marker:', style: AppText.bodyM(color: kTextDim)),
                SelectableText(
                  kBuildMarker,
                  style: AppText.bodyM(color: const Color(0xFF4ADE80)),
                ),
                const SizedBox(height: 12),
                _buildButton(
                  label: 'Check DB Tables',
                  loading: _checkingDb,
                  onTap: _checkDbTables,
                ),
                if (_dbTables != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Tables found: ${_dbTables!.join(", ")}',
                    style: AppText.bodyM(color: kText),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _dbTables!.contains('cache')
                        ? '✅ cache table EXISTS'
                        : '❌ cache table MISSING',
                    style: AppText.bodyM(
                      color: _dbTables!.contains('cache')
                          ? const Color(0xFF4ADE80)
                          : const Color(0xFFEF4444),
                    ),
                  ),
                ],
                if (_dbCheckError != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    'EXCEPTION:\n$_dbCheckError',
                    style: AppText.bodyM(color: const Color(0xFFEF4444)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- CRASH LOG (PC/logcat na hone par bhi crash-reason nikalne
          // ke liye — dekho CrashLogger.kt) ---
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2333),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF3A4560)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Crash Log', style: AppText.bodyM(color: kTextDim)),
                const SizedBox(height: 4),
                Text(
                  'App kabhi crash hui ho to yahan se seedha share kar '
                  'sakte ho — PC/adb ki zaroorat nahi.',
                  style: AppText.bodyS(color: kTextDim),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _buildButton(
                        label: 'Load + Share Crash Log',
                        loading: _loadingCrashLog,
                        onTap: _loadAndShareCrashLog,
                      ),
                    ),
                  ],
                ),
                if (_crashLogPreview != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _shareCrashLogAgain,
                        child: const Text('Share again'),
                      ),
                      TextButton(
                        onPressed: _clearCrashLog,
                        child: const Text('Clear log'),
                      ),
                    ],
                  ),
                ],
                if (_crashLogStatus != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    _crashLogStatus!,
                    style: AppText.bodyM(color: kText),
                  ),
                ],
                if (_crashLogPreview != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(maxHeight: 240),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1522),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _crashLogPreview!,
                        style: AppText.bodyS(color: const Color(0xFFEF4444)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),
          _buildButton(
            label: 'Test Search',
            loading: _searching,
            onTap: _testSearch,
          ),
          if (_searchProgress != null) ...[
            const SizedBox(height: 8),
            Text(_searchProgress!, style: AppText.bodyS(color: kTextDim)),
          ],
          const SizedBox(height: 10),
          if (_searchSummary != null)
            _resultBox(_searchSummary!, isError: _searchResults.isEmpty),
          if (_searchError != null) _errorBox(_searchError!, onRetry: _testSearch),
          if (_searchResults.isNotEmpty) ...[
            const SizedBox(height: 10),
            ..._searchResults.map(_buildResultTile),
          ],
          const SizedBox(height: 24),
          _buildButton(
            label: 'Test Audio URL (pehla result, ya hardcoded video)',
            loading: _testingAudio,
            onTap: _testAudioUrl,
          ),
          if (_audioUrlProgress != null) ...[
            const SizedBox(height: 8),
            Text(
              _audioUrlProgress!,
              style: AppText.bodyS(color: kTextDim),
            ),
          ],
          const SizedBox(height: 10),
          if (_audioUrlResult != null)
            _resultBox(
              _audioUrlResult!,
              isError: _audioUrlResult!.contains('FAIL'),
            ),
          if (_audioUrlError != null) _errorBox(_audioUrlError!, onRetry: _testAudioUrl),
          if (_audioUrlLog.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2333),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF3A4560)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Full log (har step):',
                      style: AppText.bodyM(color: kTextDim)),
                  const SizedBox(height: 6),
                  SelectableText(
                    _audioUrlLog.join('\n'),
                    style: AppText.bodyS(color: kText),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          _buildButton(
            label: 'Test Direct Video ($_kTestVideoId)',
            loading: _testingDirect,
            onTap: _testDirectVideo,
          ),
          const SizedBox(height: 10),
          if (_directResult != null)
            _resultBox(
              _directResult!,
              isError: _directResult!.contains('FAIL'),
            ),
          if (_directError != null) _errorBox(_directError!, onRetry: _testDirectVideo),
        ],
      ),
    );
  }

  Widget _buildButton({
    required String label,
    required bool loading,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: kGreen,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(label, style: AppText.bodyM(color: Colors.white)),
      ),
    );
  }

  Widget _resultBox(String text, {required bool isError}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isError ? kRed : kGreen, width: 1),
      ),
      child: Text(
        text,
        style: AppText.bodyM(color: isError ? kRed : kGreen),
      ),
    );
  }

  // NEW (2026-09-16): pehle exception dikhne ke baad user ko upar scroll
  // karke wahi button dobara dhoondhna padta tha — ab error box ke saath
  // hi ek inline "Retry" button hai jo wahi test seedha dobara chala deta
  // hai. onRetry na diya jaaye to button hi nahi dikhta (backward compatible).
  Widget _errorBox(String text, {VoidCallback? onRetry}) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kRed, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'EXCEPTION:\n$text',
            style: AppText.bodyS(color: kRed),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              child: OutlinedButton.icon(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: kRed,
                  side: const BorderSide(color: kRed),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultTile(YtResult r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              r.thumb,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 48,
                height: 48,
                color: kSurface,
                child: const Icon(Icons.music_note, color: kTextDim),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyM(color: kText),
                ),
                Text(
                  '${r.author} • ${r.duration}s',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyS(color: kTextDim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
