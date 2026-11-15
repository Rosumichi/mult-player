import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MultPlayerApp());
}

/// Общий кэш превьюшек для всех экранов и шторки в плеере
final Map<String, Uint8List?> globalThumbCache = {};

Future<Uint8List?> getGlobalThumbnail(String videoPath) async {
  if (globalThumbCache.containsKey(videoPath)) {
    return globalThumbCache[videoPath];
  }
  try {
    final bytes = await VideoThumbnail.thumbnailData(
      video: videoPath,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 320,
      quality: 75,
    );
    globalThumbCache[videoPath] = bytes;
    return bytes;
  } catch (_) {
    globalThumbCache[videoPath] = null;
    return null;
  }
}

class MultPlayerApp extends StatelessWidget {
  const MultPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'МультПлеер',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF00D2FF),
          surface: Color(0xFF181B22),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF181B22),
          elevation: 0,
        ),
      ),
      home: const LibraryScreen(),
    );
  }
}

class EpisodeItem {
  final File file;
  final String title;
  final DateTime modified;

  EpisodeItem({
    required this.file,
    required this.title,
    required this.modified,
  });
}

class CartoonGroup {
  final String key;
  final String title;
  final File? coverFile;
  final List<EpisodeItem> episodes;
  final DateTime latestDate;

  CartoonGroup({
    required this.key,
    required this.title,
    required this.coverFile,
    required this.episodes,
    required this.latestDate,
  });
}

class LastWatchedInfo {
  final CartoonGroup group;
  final int episodeIndex;
  final EpisodeItem episode;
  final int positionMs;
  final int durationMs;

  LastWatchedInfo({
    required this.group,
    required this.episodeIndex,
    required this.episode,
    required this.positionMs,
    required this.durationMs,
  });
}

enum SortMode { nameAsc, nameDesc, dateDesc, dateAsc, episodesDesc }

String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

int naturalCompare(String a, String b) {
  final reg = RegExp(r'(\d+|\D+)');
  final matchesA = reg.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final matchesB = reg.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();

  final len = matchesA.length < matchesB.length ? matchesA.length : matchesB.length;
  for (int i = 0; i < len; i++) {
    final partA = matchesA[i];
    final partB = matchesB[i];
    final numA = int.tryParse(partA);
    final numB = int.tryParse(partB);
    if (numA != null && numB != null) {
      final cmp = numA.compareTo(numB);
      if (cmp != 0) return cmp;
    } else {
      final cmp = partA.compareTo(partB);
      if (cmp != 0) return cmp;
    }
  }
  return matchesA.length.compareTo(matchesB.length);
}

String normalizeGroupKey(String rawTitle) {
  var s = rawTitle.toLowerCase();
  s = s.replaceAll(RegExp(r'[\s\u00A0._\-–—]+'), ' ').trim();

  final trailingEpPattern = RegExp(
    r'(?:\s*(?:\(\d+\)|\[\d+\]|#\d+)|\s+(?:ep|episode|ova|part|ч|часть|ser|серия|s\d+e\d+|s\d+|e\d+|v\d+)?\s*\d+)+$',
    caseSensitive: false,
  );
  final stripped = s.replaceFirst(trailingEpPattern, '').trim();
  if (stripped.isNotEmpty) {
    s = stripped;
  }
  return s;
}

String cleanDisplayTitle(String rawTitle) {
  var s = rawTitle.replaceAll(RegExp(r'[\s\u00A0]+'), ' ').trim();
  final trailingEpPattern = RegExp(
    r'[\s._\-–—]+(?:(?:\(\d+\)|\[\d+\]|#\d+)|(?:ep|episode|ova|part|ч|часть|ser|серия|s\d+e\d+)?[\s._\-]*\d+)$',
    caseSensitive: false,
  );
  final stripped = s.replaceFirst(trailingEpPattern, '').trim();
  return stripped.isNotEmpty ? stripped : s;
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final Random _rng = Random();

  String? _pinnedPath;
  List<CartoonGroup> _groups = [];
  bool _loading = false;
  int _gridColumns = 2;
  bool _containCover = false;
  SortMode _sortMode = SortMode.nameAsc;
  String _searchQuery = '';

  LastWatchedInfo? _lastWatched;
  bool _showStartupBanner = false;
  bool _startupBannerShownOnce = false;
  Uint8List? _lastWatchedThumb;

  // Настройки и память рандома
  Set<String> _usedRandomKeys = {};
  bool _randomInstantMode = false; // false = Карточка выбора, true = Сразу включать

  @override
  void initState() {
    super.initState();
    _loadPinnedFolder();
  }

  Future<void> _loadPinnedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('pinned_folder_path');
    final savedCols = prefs.getInt('grid_columns') ?? 2;
    final savedContain = prefs.getBool('contain_cover') ?? false;
    final savedUsed = prefs.getStringList('random_used_keys') ?? [];
    final savedInstant = prefs.getBool('random_instant_mode') ?? false;

    setState(() {
      _pinnedPath = savedPath;
      _gridColumns = savedCols;
      _containCover = savedContain;
      _usedRandomKeys = savedUsed.toSet();
      _randomInstantMode = savedInstant;
    });

    if (savedPath != null && savedPath.isNotEmpty) {
      await _scanDirectory(savedPath, isInitialLoad: true);
    }
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    final mediaVideo = await Permission.videos.request();
    final mediaImages = await Permission.photos.request();
    final storage = await Permission.storage.request();
    return mediaVideo.isGranted || mediaImages.isGranted || storage.isGranted;
  }

  Future<void> _pickAndPinFolder() async {
    final granted = await _ensureStoragePermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Дайте разрешение на доступ к файлам в настройках')),
      );
      return;
    }

    final selectedDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Выберите папку с мультфильмами',
    );
    if (selectedDir == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pinned_folder_path', selectedDir);
    setState(() => _pinnedPath = selectedDir);
    await _scanDirectory(selectedDir);
  }

  Future<void> _scanDirectory(String path, {bool isInitialLoad = false}) async {
    setState(() => _loading = true);
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        setState(() {
          _groups = [];
          _loading = false;
        });
        return;
      }

      final entities = dir.listSync(followLinks: false).whereType<File>().toList();
      const imageExts = {'.jpg', '.jpeg', '.png', '.webp'};
      const videoExts = {'.mp4', '.mkv', '.avi', '.mov', '.webm', '.m4v'};

      final Map<String, ({String displayName, File file})> coversByKey = {};
      final List<File> videoFiles = [];

      for (final file in entities) {
        final name = file.path.split(Platform.pathSeparator).last;
        final dotIdx = name.lastIndexOf('.');
        if (dotIdx <= 0) continue;
        final ext = name.substring(dotIdx).toLowerCase();
        final baseTitle = name.substring(0, dotIdx).trim();
        if (baseTitle.isEmpty) continue;

        if (imageExts.contains(ext)) {
          final key = normalizeGroupKey(baseTitle);
          coversByKey[key] = (
            displayName: cleanDisplayTitle(baseTitle),
            file: file,
          );
        } else if (videoExts.contains(ext)) {
          videoFiles.add(file);
        }
      }

      final sortedCoverKeys = coversByKey.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));

      final Map<String, ({String title, File? cover, List<EpisodeItem> episodes})> grouped = {};

      for (final entry in coversByKey.entries) {
        grouped[entry.key] = (
          title: entry.value.displayName,
          cover: entry.value.file,
          episodes: [],
        );
      }

      for (final video in videoFiles) {
        final fileName = video.path.split(Platform.pathSeparator).last;
        final dotIdx = fileName.lastIndexOf('.');
        final rawBase = fileName.substring(0, dotIdx).trim();
        final normalizedVideoKey = normalizeGroupKey(rawBase);
        final rawCleanLower = rawBase
            .toLowerCase()
            .replaceAll(RegExp(r'[\s\u00A0._\-–—]+'), ' ')
            .trim();

        String? matchedKey;

        if (grouped.containsKey(normalizedVideoKey)) {
          matchedKey = normalizedVideoKey;
        } else {
          for (final coverKey in sortedCoverKeys) {
            if (rawCleanLower == coverKey ||
                normalizedVideoKey == coverKey ||
                rawCleanLower.startsWith('$coverKey ') ||
                normalizedVideoKey.startsWith('$coverKey ')) {
              matchedKey = coverKey;
              break;
            }
          }
        }

        if (matchedKey == null) {
          final displayTitle = cleanDisplayTitle(rawBase);
          grouped.putIfAbsent(
            normalizedVideoKey,
            () => (
              title: displayTitle,
              cover: null,
              episodes: [],
            ),
          );
          matchedKey = normalizedVideoKey;
        }

        final stat = video.statSync();
        grouped[matchedKey]!.episodes.add(
              EpisodeItem(
                file: video,
                title: rawBase,
                modified: stat.modified,
              ),
            );
      }

      final List<CartoonGroup> result = [];
      for (final entry in grouped.entries) {
        final item = entry.value;
        if (item.episodes.isEmpty && item.cover == null) continue;
        item.episodes.sort((a, b) => naturalCompare(a.title, b.title));
        DateTime latest =
            item.cover?.statSync().modified ?? DateTime.fromMillisecondsSinceEpoch(0);
        for (final ep in item.episodes) {
          if (ep.modified.isAfter(latest)) latest = ep.modified;
        }
        result.add(
          CartoonGroup(
            key: entry.key,
            title: item.title,
            coverFile: item.cover,
            episodes: item.episodes,
            latestDate: latest,
          ),
        );
      }

      setState(() {
        _groups = result;
        _loading = false;
      });

      await _refreshLastWatched(triggerBanner: isInitialLoad);
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка чтения папки: $e')),
        );
      }
    }
  }

  Future<void> _refreshLastWatched({bool triggerBanner = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final lastVideoPath = prefs.getString('last_watched_path');
    if (lastVideoPath == null || _groups.isEmpty) {
      if (mounted) setState(() => _lastWatched = null);
      return;
    }

    CartoonGroup? foundGroup;
    int? foundIndex;
    EpisodeItem? foundEp;

    for (final g in _groups) {
      for (int i = 0; i < g.episodes.length; i++) {
        if (g.episodes[i].file.path == lastVideoPath) {
          foundGroup = g;
          foundIndex = i;
          foundEp = g.episodes[i];
          break;
        }
      }
      if (foundGroup != null) break;
    }

    if (foundGroup == null || foundEp == null || foundIndex == null) {
      if (mounted) setState(() => _lastWatched = null);
      return;
    }

    final posMs = prefs.getInt('pos_$lastVideoPath') ?? 0;
    final durMs = prefs.getInt('dur_$lastVideoPath') ?? 0;
    final thumb = await getGlobalThumbnail(lastVideoPath);

    if (mounted) {
      setState(() {
        _lastWatchedThumb = thumb;
        _lastWatched = LastWatchedInfo(
          group: foundGroup!,
          episodeIndex: foundIndex!,
          episode: foundEp!,
          positionMs: posMs,
          durationMs: durMs,
        );
        if (triggerBanner && !_startupBannerShownOnce && posMs > 1000) {
          _showStartupBanner = true;
          _startupBannerShownOnce = true;
        }
      });
    }
  }

  Future<void> _openLastWatched({required bool resume}) async {
    final lw = _lastWatched;
    if (lw == null) return;
    setState(() => _showStartupBanner = false);

    final startAt = resume ? Duration(milliseconds: lw.positionMs) : Duration.zero;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          group: lw.group,
          initialIndex: lw.episodeIndex,
          initialPosition: startAt,
          openedFromGroup: false,
        ),
      ),
    );
    await _refreshLastWatched();
  }

  // ==================== ЛОГИКА РАНДОМА ====================

  List<CartoonGroup> get _playableGroups =>
      _groups.where((g) => g.episodes.isNotEmpty).toList();

  List<CartoonGroup> get _remainingRandomGroups =>
      _playableGroups.where((g) => !_usedRandomKeys.contains(g.key)).toList();

  Future<void> _saveRandomState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('random_used_keys', _usedRandomKeys.toList());
    await prefs.setBool('random_instant_mode', _randomInstantMode);
  }

  Future<void> _resetRandomPool({bool showMessage = true}) async {
    setState(() {
      _usedRandomKeys.clear();
    });
    await _saveRandomState();
    if (showMessage && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Счётчик рандома сброшен! Доступно мультов: ${_playableGroups.length}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<({CartoonGroup group, int episodeIndex})?> _drawNextRandom() async {
    final playable = _playableGroups;
    if (playable.isEmpty) return null;

    final available = _remainingRandomGroups;
    if (available.isEmpty) {
      return null;
    }

    final pickedGroup = available[_rng.nextInt(available.length)];
    final pickedEpIndex = _rng.nextInt(pickedGroup.episodes.length);

    setState(() {
      _usedRandomKeys.add(pickedGroup.key);
    });
    await _saveRandomState();

    return (group: pickedGroup, episodeIndex: pickedEpIndex);
  }

  Future<void> _onRandomButtonPressed() async {
    if (_playableGroups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет доступных мультфильмов с сериями')),
      );
      return;
    }

    if (_remainingRandomGroups.isEmpty) {
      final reset = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF181B22),
          title: const Text('Все мульты уже выпадали!'),
          content: Text(
            'Вы прокрутили все ${_playableGroups.length} мультов из списка. Сбросить счётчик и начать заново?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Сбросить счётчик', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (reset != true) return;
      await _resetRandomPool(showMessage: false);
    }

    if (_randomInstantMode) {
      // Режим 1: сразу открываем плеер со случайным мультом и серией
      final picked = await _drawNextRandom();
      if (picked == null || !mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            group: picked.group,
            initialIndex: picked.episodeIndex,
            initialPosition: Duration.zero,
            openedFromGroup: false,
          ),
        ),
      );
      await _refreshLastWatched();
    } else {
      // Режим 2: открываем карточку рандома
      await _openRandomCardModal();
    }
  }

  Future<void> _openRandomCardModal() async {
    var currentPick = await _drawNextRandom();
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final totalCount = _playableGroups.length;
            final leftCount = _remainingRandomGroups.length;
            final group = currentPick?.group;
            final epIdx = currentPick?.episodeIndex ?? 0;
            final ep = (group != null && group.episodes.isNotEmpty)
                ? group.episodes[epIdx]
                : null;

            return Dialog(
              backgroundColor: const Color(0xFF181B22),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Шапка карточки с крестиком и счётчиком
                    Row(
                      children: [
                        const Icon(Icons.casino, color: Color(0xFF00D2FF), size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Случайный мульт • Осталось: $leftCount из $totalCount',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (group == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          children: [
                            const Icon(Icons.check_circle_outline,
                                size: 48, color: Color(0xFF00D2FF)),
                            const SizedBox(height: 10),
                            const Text(
                              'Все мульты уже выпали!',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Нажмите «Сбросить счётчик» ниже, чтобы запустить круг заново.',
                              style: TextStyle(fontSize: 13, color: Colors.white60),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    else ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 210,
                          child: group.coverFile != null
                              ? Image.file(group.coverFile!, fit: BoxFit.cover)
                              : Container(
                                  color: const Color(0xFF222631),
                                  child: const Icon(Icons.movie,
                                      size: 56, color: Colors.white38),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        group.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (ep != null)
                        Text(
                          'Выпала серия ${epIdx + 1} из ${group.episodes.length}: ${ep.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF00D2FF),
                          ),
                        ),
                      const SizedBox(height: 16),

                      // Кнопка Смотреть
                      ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await Navigator.push(
                            this.context,
                            MaterialPageRoute(
                              builder: (_) => VideoPlayerScreen(
                                group: group,
                                initialIndex: epIdx,
                                initialPosition: Duration.zero,
                                openedFromGroup: false,
                              ),
                            ),
                          );
                          await _refreshLastWatched();
                        },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Смотреть серию'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C63FF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Кнопка Открыть группу мульта
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await Navigator.push(
                            this.context,
                            MaterialPageRoute(
                              builder: (_) => CartoonDetailScreen(group: group),
                            ),
                          );
                          await _refreshLastWatched();
                        },
                        icon: const Icon(Icons.video_library, size: 18),
                        label: const Text('Перейти к мульту (все серии)'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                    ],

                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _remainingRandomGroups.isEmpty
                                ? null
                                : () async {
                                    final next = await _drawNextRandom();
                                    setModalState(() {
                                      currentPick = next;
                                    });
                                  },
                            icon: const Icon(Icons.shuffle, size: 18),
                            label: const Text('Перерандомить'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF00D2FF),
                              side: const BorderSide(color: Color(0xFF00D2FF)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Сбросить счётчик рандома',
                          onPressed: () async {
                            await _resetRandomPool(showMessage: false);
                            final fresh = await _drawNextRandom();
                            setModalState(() {
                              currentPick = fresh;
                            });
                          },
                          icon: const Icon(Icons.restart_alt, color: Colors.white70),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<CartoonGroup> get _filteredAndSortedGroups {
    final list = _groups
        .where((g) => g.title.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    switch (_sortMode) {
      case SortMode.nameAsc:
        list.sort((a, b) => naturalCompare(a.title, b.title));
      case SortMode.nameDesc:
        list.sort((a, b) => naturalCompare(b.title, a.title));
      case SortMode.dateDesc:
        list.sort((a, b) => b.latestDate.compareTo(a.latestDate));
      case SortMode.dateAsc:
        list.sort((a, b) => a.latestDate.compareTo(b.latestDate));
      case SortMode.episodesDesc:
        list.sort((a, b) => b.episodes.length.compareTo(a.episodes.length));
    }
    return list;
  }

  void _openScaleSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Масштаб карточек и обложек',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Колонок в ряд: '),
                      Expanded(
                        child: Slider(
                          value: _gridColumns.toDouble(),
                          min: 1,
                          max: 4,
                          divisions: 3,
                          label: '$_gridColumns',
                          onChanged: (val) async {
                            final cols = val.round();
                            setSheetState(() => _gridColumns = cols);
                            setState(() => _gridColumns = cols);
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setInt('grid_columns', cols);
                          },
                        ),
                      ),
                      Text('$_gridColumns'),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Показывать обложку целиком без обрезки'),
                    value: _containCover,
                    onChanged: (val) async {
                      setSheetState(() => _containCover = val);
                      setState(() => _containCover = val);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('contain_cover', val);
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildStartupFloatingBanner(LastWatchedInfo lw) {
    final posText = formatDuration(Duration(milliseconds: lw.positionMs));
    return Dismissible(
      key: const ValueKey('startup_continue_banner'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => setState(() => _showStartupBanner = false),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF282442), Color(0xFF1A1D26)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.6)),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.play_circle_fill, color: Color(0xFF00D2FF), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Вы смотрели: ${lw.episode.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                  onPressed: () => setState(() => _showStartupBanner = false),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _openLastWatched(resume: true),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text('Продолжить ($posText)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () => _openLastWatched(resume: false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                  child: const Text('Начать заново'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRandomControlBar() {
    final total = _playableGroups.length;
    final left = _remainingRandomGroups.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF181B22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _onRandomButtonPressed,
                icon: const Icon(Icons.casino, size: 18),
                label: Text(
                  'Рандом ($left из $total)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Переключатель режима: Сразу включать ИЛИ Карточка
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () async {
                setState(() => _randomInstantMode = !_randomInstantMode);
                await _saveRandomState();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF222631),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _randomInstantMode ? Icons.bolt : Icons.style,
                      size: 16,
                      color: const Color(0xFF00D2FF),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _randomInstantMode ? 'Сразу' : 'Карточка',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Сбросить счётчик рандома',
              icon: const Icon(Icons.restart_alt, size: 20, color: Colors.white70),
              onPressed: () => _resetRandomPool(showMessage: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLastWatchedTopSection(LastWatchedInfo lw) {
    final progress = lw.durationMs > 0
        ? (lw.positionMs / lw.durationMs).clamp(0.0, 1.0)
        : 0.0;
    final posText = formatDuration(Duration(milliseconds: lw.positionMs));
    final durText = lw.durationMs > 0
        ? formatDuration(Duration(milliseconds: lw.durationMs))
        : '--:--';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              'Последнее просмотренное',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openLastWatched(resume: true),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF181B22),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 110,
                        height: 66,
                        child: _lastWatchedThumb != null
                            ? Image.memory(_lastWatchedThumb!, fit: BoxFit.cover)
                            : lw.group.coverFile != null
                                ? Image.file(lw.group.coverFile!, fit: BoxFit.cover)
                                : Container(
                                    color: const Color(0xFF222631),
                                    child: const Icon(Icons.history, color: Colors.white54),
                                  ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                lw.group.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                lw.episode.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$posText / $durText',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF00D2FF),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Начать с начала',
                        icon: const Icon(Icons.replay, color: Colors.white60, size: 22),
                        onPressed: () => _openLastWatched(resume: false),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: Icon(
                          Icons.play_circle_fill,
                          color: Color(0xFF6C63FF),
                          size: 32,
                        ),
                      ),
                    ],
                  ),
                  if (progress > 0)
                    LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      color: const Color(0xFF6C63FF),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredAndSortedGroups;

    return Scaffold(
      appBar: AppBar(
        title: const Text('МультПлеер', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Случайный мульт',
            icon: const Icon(Icons.casino),
            onPressed: _onRandomButtonPressed,
          ),
          IconButton(
            tooltip: 'Масштаб картинок',
            icon: const Icon(Icons.zoom_in),
            onPressed: _openScaleSheet,
          ),
          PopupMenuButton<SortMode>(
            tooltip: 'Сортировка',
            icon: const Icon(Icons.sort),
            onSelected: (mode) => setState(() => _sortMode = mode),
            itemBuilder: (_) => const [
              PopupMenuItem(value: SortMode.nameAsc, child: Text('По названию (А → Я)')),
              PopupMenuItem(value: SortMode.nameDesc, child: Text('По названию (Я → А)')),
              PopupMenuItem(value: SortMode.dateDesc, child: Text('По дате (сначала новые)')),
              PopupMenuItem(value: SortMode.dateAsc, child: Text('По дате (сначала старые)')),
              PopupMenuItem(value: SortMode.episodesDesc, child: Text('По количеству серий')),
            ],
          ),
          IconButton(
            tooltip: 'Закрепить папку',
            icon: const Icon(Icons.folder_open),
            onPressed: _pickAndPinFolder,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_pinnedPath != null)
            Container(
              width: double.infinity,
              color: const Color(0xFF14171D),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.push_pin, size: 16, color: Color(0xFF6C63FF)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _pinnedPath!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                  InkWell(
                    onTap: () => _scanDirectory(_pinnedPath!),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Icon(Icons.refresh, size: 18, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),

          if (_showStartupBanner && _lastWatched != null)
            _buildStartupFloatingBanner(_lastWatched!),

          if (_groups.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Поиск мультфильма...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF181B22),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
            _buildRandomControlBar(),
          ],

          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _pinnedPath == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.video_library_outlined,
                                  size: 72, color: Colors.white38),
                              const SizedBox(height: 16),
                              const Text(
                                'Папка с мультфильмами не выбрана',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Закрепите папку вида "name .jpg", "name 1.mp4", "name 2.mp4" — программа сама разделит серии по мультам.',
                                style: TextStyle(color: Colors.white60),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton.icon(
                                onPressed: _pickAndPinFolder,
                                icon: const Icon(Icons.folder),
                                label: const Text('Закрепить папку'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF6C63FF),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 14),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : CustomScrollView(
                        slivers: [
                          if (_lastWatched != null && _searchQuery.isEmpty)
                            SliverToBoxAdapter(
                              child: _buildLastWatchedTopSection(_lastWatched!),
                            ),
                          if (items.isEmpty)
                            const SliverFillRemaining(
                              child: Center(
                                child: Text(
                                  'В этой папке не найдено мультфильмов',
                                  style: TextStyle(color: Colors.white60),
                                ),
                              ),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.all(12),
                              sliver: SliverGrid(
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _gridColumns,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: _gridColumns == 1 ? 1.5 : 0.72,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final group = items[index];
                                    return _CartoonCard(
                                      group: group,
                                      containCover: _containCover,
                                      onTap: () async {
                                        await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                CartoonDetailScreen(group: group),
                                          ),
                                        );
                                        await _refreshLastWatched();
                                      },
                                    );
                                  },
                                  childCount: items.length,
                                ),
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _CartoonCard extends StatelessWidget {
  final CartoonGroup group;
  final bool containCover;
  final VoidCallback onTap;

  const _CartoonCard({
    required this.group,
    required this.containCover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF181B22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: group.coverFile != null
                  ? Image.file(
                      group.coverFile!,
                      fit: containCover ? BoxFit.contain : BoxFit.cover,
                    )
                  : Container(
                      color: const Color(0xFF222631),
                      child: const Icon(Icons.movie, size: 48, color: Colors.white38),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Серий: ${group.episodes.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CartoonDetailScreen extends StatefulWidget {
  final CartoonGroup group;

  const CartoonDetailScreen({super.key, required this.group});

  @override
  State<CartoonDetailScreen> createState() => _CartoonDetailScreenState();
}

class _CartoonDetailScreenState extends State<CartoonDetailScreen> {
  Map<String, int> _savedPositions = {};
  Map<String, int> _savedDurations = {};
  double _previewScale = 1.0;

  // Состояние превью-проигрывателя обрывков
  VideoPlayerController? _previewController;
  Timer? _snippetTimer;
  String? _previewingEpisodePath;
  int _currentSnippetIndex = 0;
  double _dragDistanceX = 0.0;

  static const List<double> _snippetFractions = [0.10, 0.25, 0.40, 0.55, 0.70, 0.85];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final posMap = <String, int>{};
    final durMap = <String, int>{};
    for (final ep in widget.group.episodes) {
      posMap[ep.file.path] = prefs.getInt('pos_${ep.file.path}') ?? 0;
      durMap[ep.file.path] = prefs.getInt('dur_${ep.file.path}') ?? 0;
    }
    if (mounted) {
      setState(() {
        _savedPositions = posMap;
        _savedDurations = durMap;
      });
    }
  }

  Future<void> _stopSnippetPreview() async {
    _snippetTimer?.cancel();
    _snippetTimer = null;
    final old = _previewController;
    _previewController = null;
    _previewingEpisodePath = null;
    if (mounted) setState(() {});
    await old?.dispose();
  }

  Future<void> _startSnippetPreview(EpisodeItem ep) async {
    await _stopSnippetPreview();
    if (!mounted) return;

    setState(() {
      _previewingEpisodePath = ep.file.path;
      _currentSnippetIndex = 0;
    });

    try {
      final controller = VideoPlayerController.file(ep.file);
      await controller.initialize();
      if (!mounted || _previewingEpisodePath != ep.file.path) {
        await controller.dispose();
        return;
      }
      await controller.setVolume(0.0);

      final totalMs = controller.value.duration.inMilliseconds;
      if (totalMs > 1000) {
        final firstTarget = (totalMs * _snippetFractions[0]).round();
        await controller.seekTo(Duration(milliseconds: firstTarget));
      }
      await controller.play();

      setState(() {
        _previewController = controller;
      });

      _snippetTimer = Timer.periodic(const Duration(milliseconds: 2400), (_) async {
        final c = _previewController;
        if (c == null || !c.value.isInitialized || !mounted) return;
        final nextIdx = (_currentSnippetIndex + 1) % _snippetFractions.length;
        final dur = c.value.duration.inMilliseconds;
        if (dur > 1000) {
          final targetMs = (dur * _snippetFractions[nextIdx]).round();
          await c.seekTo(Duration(milliseconds: targetMs));
        }
        if (mounted) {
          setState(() {
            _currentSnippetIndex = nextIdx;
          });
        }
      });
    } catch (_) {
      await _stopSnippetPreview();
    }
  }

  void _openCoverZoom() {
    if (widget.group.coverFile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, title: Text(widget.group.title)),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: Image.file(widget.group.coverFile!),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onEpisodeTap(int index) async {
    await _stopSnippetPreview();
    if (!mounted) return;

    final ep = widget.group.episodes[index];
    final savedMs = _savedPositions[ep.file.path] ?? 0;
    final durMs = _savedDurations[ep.file.path] ?? 0;

    Duration startAt = Duration.zero;
    if (savedMs > 3000 && (durMs == 0 || savedMs < durMs - 3000)) {
      final resume = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF181B22),
          title: Text(ep.title),
          content: Text(
            'Вы остановились на ${formatDuration(Duration(milliseconds: savedMs))}. Продолжить просмотр?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Начать заново'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Продолжить (${formatDuration(Duration(milliseconds: savedMs))})',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
      if (resume == null) return;
      if (resume) {
        startAt = Duration(milliseconds: savedMs);
      }
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          group: widget.group,
          initialIndex: index,
          initialPosition: startAt,
          openedFromGroup: true,
        ),
      ),
    );
    await _loadHistory();
  }

  @override
  void dispose() {
    _snippetTimer?.cancel();
    _previewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.title),
        actions: [
          IconButton(
            tooltip: 'Размер превью',
            icon: const Icon(Icons.photo_size_select_large),
            onPressed: () {
              setState(() {
                _previewScale = _previewScale >= 1.5 ? 1.0 : _previewScale + 0.25;
              });
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (widget.group.coverFile != null)
            GestureDetector(
              onTap: _openCoverZoom,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Image.file(
                      widget.group.coverFile!,
                      height: 200 * _previewScale,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                    Container(
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_in, size: 16),
                          SizedBox(width: 4),
                          Text('Открыть и приблизить', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                'Серии (${widget.group.episodes.length})',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Свайп вправо по серии → превью-обрывки',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...List.generate(widget.group.episodes.length, (index) {
            final ep = widget.group.episodes[index];
            final posMs = _savedPositions[ep.file.path] ?? 0;
            final durMs = _savedDurations[ep.file.path] ?? 0;
            final progress = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;
            final isPreviewingThis = _previewingEpisodePath == ep.file.path;

            return GestureDetector(
              onHorizontalDragStart: (_) {
                _dragDistanceX = 0.0;
              },
              onHorizontalDragUpdate: (details) {
                _dragDistanceX += details.delta.dx;
              },
              onHorizontalDragEnd: (_) {
                // Если приложили палец, провели вправо и убрали палец — включаем обрывки на превьюшке
                if (_dragDistanceX > 35) {
                  _startSnippetPreview(ep);
                } else if (_dragDistanceX < -35 && isPreviewingThis) {
                  _stopSnippetPreview();
                }
                _dragDistanceX = 0.0;
              },
              child: Card(
                color: const Color(0xFF181B22),
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isPreviewingThis
                      ? const BorderSide(color: Color(0xFF00D2FF), width: 1.5)
                      : BorderSide.none,
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _onEpisodeTap(index),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 140 * _previewScale,
                            height: 82 * _previewScale,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (isPreviewingThis &&
                                    _previewController != null &&
                                    _previewController!.value.isInitialized)
                                  FittedBox(
                                    fit: BoxFit.cover,
                                    clipBehavior: Clip.hardEdge,
                                    child: SizedBox(
                                      width: _previewController!.value.size.width,
                                      height: _previewController!.value.size.height,
                                      child: VideoPlayer(_previewController!),
                                    ),
                                  )
                                else
                                  FutureBuilder<Uint8List?>(
                                    future: getGlobalThumbnail(ep.file.path),
                                    builder: (context, snap) {
                                      if (snap.hasData && snap.data != null) {
                                        return Image.memory(snap.data!, fit: BoxFit.cover);
                                      }
                                      return Container(
                                        color: const Color(0xFF222631),
                                        child: const Icon(Icons.play_circle_outline, size: 32),
                                      );
                                    },
                                  ),

                                if (isPreviewingThis)
                                  Positioned(
                                    top: 4,
                                    left: 4,
                                    right: 4,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.black87,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            'Обрывок ${_currentSnippetIndex + 1}/${_snippetFractions.length}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xFF00D2FF),
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        GestureDetector(
                                          onTap: _stopSnippetPreview,
                                          child: Container(
                                            padding: const EdgeInsets.all(2),
                                            decoration: const BoxDecoration(
                                              color: Colors.black87,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(Icons.close,
                                                size: 14, color: Colors.white),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    ep.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (posMs > 3000)
                                    Text(
                                      'Просмотрено до ${formatDuration(Duration(milliseconds: posMs))}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF00D2FF),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(right: 12),
                            child: Icon(Icons.play_arrow_rounded,
                                size: 30, color: Color(0xFF6C63FF)),
                          ),
                        ],
                      ),
                      if (progress > 0)
                        LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          color: const Color(0xFF6C63FF),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final CartoonGroup group;
  final int initialIndex;
  final Duration initialPosition;
  final bool openedFromGroup;

  const VideoPlayerScreen({
    super.key,
    required this.group,
    required this.initialIndex,
    required this.initialPosition,
    required this.openedFromGroup,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late int _currentIndex;
  VideoPlayerController? _controller;

  bool _isLandscape = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _saveTimer;

  bool _isScrubbing = false;
  Duration _scrubTargetPos = Duration.zero;

  String? _seekBadgeText;
  Timer? _badgeTimer;

  List<EpisodeItem> get _episodes => widget.group.episodes;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initEpisode(_currentIndex, startPos: widget.initialPosition);
  }

  Future<void> _initEpisode(int index, {Duration startPos = Duration.zero}) async {
    await _saveCurrentProgress();
    final oldController = _controller;
    setState(() {
      _controller = null;
      _currentIndex = index;
    });
    await oldController?.dispose();

    final ep = _episodes[index];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_watched_path', ep.file.path);

    final controller = VideoPlayerController.file(ep.file);
    await controller.initialize();
    if (startPos > Duration.zero && startPos < controller.value.duration) {
      await controller.seekTo(startPos);
    }
    await controller.play();
    await _saveCurrentProgress();

    controller.addListener(() {
      if (mounted) setState(() {});
    });

    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 3), (_) => _saveCurrentProgress());

    if (mounted) {
      setState(() => _controller = controller);
      _restartHideTimer();
    }
  }

  Future<void> _saveCurrentProgress() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final ep = _episodes[_currentIndex];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_watched_path', ep.file.path);
    await prefs.setInt('pos_${ep.file.path}', c.value.position.inMilliseconds);
    await prefs.setInt('dur_${ep.file.path}', c.value.duration.inMilliseconds);
  }

  void _toggleOrientation() {
    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _seekRelative(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final current = c.value.position;
    final total = c.value.duration;
    var target = current + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    c.seekTo(target);

    _badgeTimer?.cancel();
    setState(() {
      _seekBadgeText = seconds > 0 ? '+$seconds сек' : '$seconds сек';
    });
    _badgeTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _seekBadgeText = null);
    });
  }

  Future<void> _goToCartoonGroup() async {
    await _saveCurrentProgress();
    if (!mounted) return;
    if (widget.openedFromGroup) {
      // Если плеер открыт из группы мульта — просто возвращаемся в неё
      Navigator.pop(context);
    } else {
      // Если плеер открыт с главного экрана ("Продолжить" или "Рандом") — заменяем плеер на экран группы мульта
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => CartoonDetailScreen(group: widget.group),
        ),
      );
    }
  }

  Future<void> _openEpisodesAndGroupSheet() async {
    _hideTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181B22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Column(
              children: [
                // Верхняя шапка шторки с кнопкой "Перейти к мульту"
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.group.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Всего серий: ${_episodes.length}',
                              style: const TextStyle(fontSize: 12, color: Colors.white60),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _goToCartoonGroup();
                        },
                        icon: const Icon(Icons.video_library, size: 18),
                        label: const Text('Перейти к мульту'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C63FF),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),

                // Список всех серий с превьюшками
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _episodes.length,
                    itemBuilder: (context, index) {
                      final ep = _episodes[index];
                      final isCurrent = index == _currentIndex;
                      final posMs = prefs.getInt('pos_${ep.file.path}') ?? 0;
                      final durMs = prefs.getInt('dur_${ep.file.path}') ?? 0;
                      final progress = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

                      return Card(
                        color: isCurrent
                            ? const Color(0xFF282442)
                            : const Color(0xFF14171D),
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: isCurrent
                              ? const BorderSide(color: Color(0xFF6C63FF), width: 1.5)
                              : BorderSide.none,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            if (index != _currentIndex) {
                              _initEpisode(index);
                            }
                          },
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  SizedBox(
                                    width: 120,
                                    height: 70,
                                    child: FutureBuilder<Uint8List?>(
                                      future: getGlobalThumbnail(ep.file.path),
                                      builder: (context, snap) {
                                        if (snap.hasData && snap.data != null) {
                                          return Image.memory(snap.data!, fit: BoxFit.cover);
                                        }
                                        return Container(
                                          color: const Color(0xFF222631),
                                          child: const Icon(Icons.play_circle_outline),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            ep.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                              color: isCurrent
                                                  ? const Color(0xFF00D2FF)
                                                  : Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            isCurrent
                                                ? 'Сейчас играет'
                                                : posMs > 3000
                                                    ? 'До ${formatDuration(Duration(milliseconds: posMs))}'
                                                    : 'Серия ${index + 1}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 12),
                                    child: Icon(
                                      isCurrent
                                          ? Icons.equalizer
                                          : Icons.play_arrow_rounded,
                                      color: const Color(0xFF6C63FF),
                                    ),
                                  ),
                                ],
                              ),
                              if (progress > 0)
                                LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 3,
                                  backgroundColor: Colors.white12,
                                  color: const Color(0xFF6C63FF),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    _restartHideTimer();
  }

  @override
  void dispose() {
    _saveCurrentProgress();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _badgeTimer?.cancel();
    _controller?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ep = _episodes[_currentIndex];
    final hasPrev = _currentIndex > 0;
    final hasNext = _currentIndex < _episodes.length - 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = constraints.maxWidth;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_showControls) {
                setState(() => _showControls = false);
              } else {
                _restartHideTimer();
              }
            },
            onDoubleTapDown: (details) {
              final x = details.localPosition.dx;
              if (x < screenWidth * 0.35) {
                _seekRelative(-10);
              } else if (x > screenWidth * 0.65) {
                _seekRelative(10);
              } else if (c != null && c.value.isInitialized) {
                c.value.isPlaying ? c.pause() : c.play();
              }
            },
            onHorizontalDragStart: (details) {
              if (c == null || !c.value.isInitialized) return;
              setState(() {
                _isScrubbing = true;
                _scrubTargetPos = c.value.position;
              });
            },
            onHorizontalDragUpdate: (details) {
              if (!_isScrubbing || c == null) return;
              final ratio = details.delta.dx / screenWidth;
              final deltaMs = (ratio * 90000).round();
              var next = _scrubTargetPos + Duration(milliseconds: deltaMs);
              if (next < Duration.zero) next = Duration.zero;
              if (next > c.value.duration) next = c.value.duration;
              setState(() => _scrubTargetPos = next);
            },
            onHorizontalDragEnd: (_) {
              if (!_isScrubbing || c == null) return;
              c.seekTo(_scrubTargetPos);
              setState(() => _isScrubbing = false);
            },
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (c != null && c.value.isInitialized)
                  Center(
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: VideoPlayer(c),
                    ),
                  )
                else
                  const CircularProgressIndicator(color: Color(0xFF6C63FF)),

                if (_isScrubbing && c != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${formatDuration(_scrubTargetPos)} / ${formatDuration(c.value.duration)}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),

                if (_seekBadgeText != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _seekBadgeText!,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00D2FF),
                      ),
                    ),
                  ),

                if (_showControls)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black45,
                      child: SafeArea(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Верхняя панель с кнопкой "Серии / К мульту"
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                                    onPressed: () => Navigator.pop(context),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          ep.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                          ),
                                        ),
                                        Text(
                                          '${widget.group.title} • Серия ${_currentIndex + 1} из ${_episodes.length}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: _openEpisodesAndGroupSheet,
                                    icon: const Icon(Icons.playlist_play,
                                        color: Color(0xFF00D2FF)),
                                    label: const Text(
                                      'Серии',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Повернуть экран принудительно',
                                    icon: const Icon(Icons.screen_rotation, color: Colors.white),
                                    onPressed: _toggleOrientation,
                                  ),
                                ],
                              ),
                            ),

                            // Центральные кнопки переключения серий
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  iconSize: 40,
                                  tooltip: 'Предыдущая серия этого мульта',
                                  onPressed:
                                      hasPrev ? () => _initEpisode(_currentIndex - 1) : null,
                                  icon: Icon(
                                    Icons.skip_previous_rounded,
                                    color: hasPrev ? Colors.white : Colors.white24,
                                  ),
                                ),
                                const SizedBox(width: 24),
                                IconButton(
                                  iconSize: 56,
                                  onPressed: () {
                                    if (c == null || !c.value.isInitialized) return;
                                    c.value.isPlaying ? c.pause() : c.play();
                                    _restartHideTimer();
                                  },
                                  icon: Icon(
                                    (c?.value.isPlaying ?? false)
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_filled,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 24),
                                IconButton(
                                  iconSize: 40,
                                  tooltip: 'Следующая серия этого мульта',
                                  onPressed:
                                      hasNext ? () => _initEpisode(_currentIndex + 1) : null,
                                  icon: Icon(
                                    Icons.skip_next_rounded,
                                    color: hasNext ? Colors.white : Colors.white24,
                                  ),
                                ),
                              ],
                            ),

                            // Нижняя шкала времени
                            if (c != null && c.value.isInitialized)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Row(
                                  children: [
                                    Text(
                                      formatDuration(c.value.position),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    Expanded(
                                      child: Slider(
                                        value: c.value.position.inMilliseconds
                                            .clamp(0, c.value.duration.inMilliseconds)
                                            .toDouble(),
                                        min: 0,
                                        max: c.value.duration.inMilliseconds
                                            .toDouble()
                                            .clamp(1, double.infinity),
                                        activeColor: const Color(0xFF6C63FF),
                                        onChanged: (v) {
                                          c.seekTo(Duration(milliseconds: v.round()));
                                          _restartHideTimer();
                                        },
                                      ),
                                    ),
                                    Text(
                                      formatDuration(c.value.duration),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              )
                            else
                              const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
