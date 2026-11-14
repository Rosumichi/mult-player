import 'dart:async';
import 'dart:io';
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
  final String title;
  final File? coverFile;
  final List<EpisodeItem> episodes;
  final DateTime latestDate;

  CartoonGroup({
    required this.title,
    required this.coverFile,
    required this.episodes,
    required this.latestDate,
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

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String? _pinnedPath;
  List<CartoonGroup> _groups = [];
  bool _loading = false;
  int _gridColumns = 2;
  bool _containCover = false;
  SortMode _sortMode = SortMode.nameAsc;
  String _searchQuery = '';

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
    setState(() {
      _pinnedPath = savedPath;
      _gridColumns = savedCols;
      _containCover = savedContain;
    });
    if (savedPath != null && savedPath.isNotEmpty) {
      await _scanDirectory(savedPath);
    }
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    final mediaVideo = await Permission.videos.request();
    final mediaImages = await Permission.images.request();
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

  Future<void> _scanDirectory(String path) async {
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

      final Map<String, ({String displayName, File file})> coversByLowerName = {};
      final List<File> videoFiles = [];

      for (final file in entities) {
        final name = file.uri.pathSegments.last;
        final dotIdx = name.lastIndexOf('.');
        if (dotIdx <= 0) continue;
        final ext = name.substring(dotIdx).toLowerCase();
        // Убираем пробел перед расширением ("name .jpg" -> "name")
        final baseTitle = name.substring(0, dotIdx).trim();
        if (baseTitle.isEmpty) continue;

        if (imageExts.contains(ext)) {
          coversByLowerName[baseTitle.toLowerCase()] = (
            displayName: baseTitle,
            file: file,
          );
        } else if (videoExts.contains(ext)) {
          videoFiles.add(file);
        }
      }

      // Сортируем ключи обложек от длинных к коротким для точного сопоставления
      final sortedCoverKeys = coversByLowerName.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));

      final Map<String, ({String title, File? cover, List<EpisodeItem> episodes})> grouped = {};

      for (final entry in coversByLowerName.entries) {
        grouped[entry.key] = (
          title: entry.value.displayName,
          cover: entry.value.file,
          episodes: [],
        );
      }

      final trailingEpisodeReg = RegExp(
        r'[\s._-]+(?:ep|ser|серия|s\d+e)?\d+$',
        caseSensitive: false,
      );

      for (final video in videoFiles) {
        final fileName = video.uri.pathSegments.last;
        final dotIdx = fileName.lastIndexOf('.');
        final rawBase = fileName.substring(0, dotIdx).trim();
        final rawLower = rawBase.toLowerCase();

        String? matchedKey;
        for (final coverKey in sortedCoverKeys) {
          if (rawLower == coverKey) {
            matchedKey = coverKey;
            break;
          }
          if (rawLower.startsWith(coverKey)) {
            final remainder = rawLower.substring(coverKey.length);
            if (RegExp(r'^[\s._-]').hasMatch(remainder)) {
              matchedKey = coverKey;
              break;
            }
          }
        }

        if (matchedKey == null) {
          final fallbackTitle = rawBase.replaceFirst(trailingEpisodeReg, '').trim();
          final key = (fallbackTitle.isEmpty ? rawBase : fallbackTitle).toLowerCase();
          grouped.putIfAbsent(
            key,
            () => (
              title: fallbackTitle.isEmpty ? rawBase : fallbackTitle,
              cover: null,
              episodes: [],
            ),
          );
          matchedKey = key;
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
      for (final item in grouped.values) {
        if (item.episodes.isEmpty && item.cover == null) continue;
        item.episodes.sort((a, b) => naturalCompare(a.title, b.title));
        DateTime latest = item.cover?.statSync().modified ?? DateTime.fromMillisecondsSinceEpoch(0);
        for (final ep in item.episodes) {
          if (ep.modified.isAfter(latest)) latest = ep.modified;
        }
        result.add(
          CartoonGroup(
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
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка чтения папки: $e')),
        );
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final items = _filteredAndSortedGroups;

    return Scaffold(
      appBar: AppBar(
        title: const Text('МультПлеер', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
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
          if (_groups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
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
                              const Icon(Icons.video_library_outlined, size: 72, color: Colors.white38),
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
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : items.isEmpty
                        ? const Center(
                            child: Text(
                              'В этой папке не найдено мультфильмов',
                              style: TextStyle(color: Colors.white60),
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.all(12),
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: _gridColumns,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: _gridColumns == 1 ? 1.5 : 0.72,
                            ),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final group = items[index];
                              return _CartoonCard(
                                group: group,
                                containCover: _containCover,
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CartoonDetailScreen(group: group),
                                    ),
                                  );
                                  setState(() {});
                                },
                              );
                            },
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
  final Map<String, Uint8List?> _thumbCache = {};
  Map<String, int> _savedPositions = {};
  Map<String, int> _savedDurations = {};
  double _previewScale = 1.0;

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

  Future<Uint8List?> _getThumbnail(String videoPath) async {
    if (_thumbCache.containsKey(videoPath)) return _thumbCache[videoPath];
    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 320,
        quality: 75,
      );
      _thumbCache[videoPath] = bytes;
      return bytes;
    } catch (_) {
      _thumbCache[videoPath] = null;
      return null;
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
          cartoonTitle: widget.group.title,
          episodes: widget.group.episodes,
          initialIndex: index,
          initialPosition: startAt,
        ),
      ),
    );
    await _loadHistory();
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
          Text(
            'Серии (${widget.group.episodes.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ...List.generate(widget.group.episodes.length, (index) {
            final ep = widget.group.episodes[index];
            final posMs = _savedPositions[ep.file.path] ?? 0;
            final durMs = _savedDurations[ep.file.path] ?? 0;
            final progress = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;

            return Card(
              color: const Color(0xFF181B22),
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _onEpisodeTap(index),
                child: Column(
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 130 * _previewScale,
                          height: 76 * _previewScale,
                          child: FutureBuilder<Uint8List?>(
                            future: _getThumbnail(ep.file.path),
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
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
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
                          child: Icon(Icons.play_arrow_rounded, size: 30, color: Color(0xFF6C63FF)),
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
          }),
        ],
      ),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String cartoonTitle;
  final List<EpisodeItem> episodes;
  final int initialIndex;
  final Duration initialPosition;

  const VideoPlayerScreen({
    super.key,
    required this.cartoonTitle,
    required this.episodes,
    required this.initialIndex,
    required this.initialPosition,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late int _currentIndex;
  VideoPlayerController? _controller;
  final TransformationController _transformController = TransformationController();
  double _videoScale = 1.0;

  bool _isLandscape = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _saveTimer;

  // Переменные для плавного свайпа перемотки
  bool _isScrubbing = false;
  Duration _scrubStartPos = Duration.zero;
  Duration _scrubTargetPos = Duration.zero;

  // Индикатор двойного тапа (-10с / +10с)
  String? _seekBadgeText;
  Timer? _badgeTimer;

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

    final ep = widget.episodes[index];
    final controller = VideoPlayerController.file(ep.file);
    await controller.initialize();
    if (startPos > Duration.zero && startPos < controller.value.duration) {
      await controller.seekTo(startPos);
    }
    await controller.play();

    controller.addListener(() {
      if (mounted) setState(() {});
    });

    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 4), (_) => _saveCurrentProgress());

    if (mounted) {
      setState(() => _controller = controller);
      _restartHideTimer();
    }
  }

  Future<void> _saveCurrentProgress() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final ep = widget.episodes[_currentIndex];
    final prefs = await SharedPreferences.getInstance();
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

  void _setVideoScale(double scale) {
    final clamped = scale.clamp(0.5, 3.5);
    setState(() {
      _videoScale = clamped;
      _transformController.value = Matrix4.identity()..scale(clamped);
    });
  }

  @override
  void dispose() {
    _saveCurrentProgress();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _badgeTimer?.cancel();
    _controller?.dispose();
    _transformController.dispose();
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
    final ep = widget.episodes[_currentIndex];
    final hasPrev = _currentIndex > 0;
    final hasNext = _currentIndex < widget.episodes.length - 1;

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
              if (c == null || !c.value.isInitialized || _videoScale > 1.02) return;
              setState(() {
                _isScrubbing = true;
                _scrubStartPos = c.value.position;
                _scrubTargetPos = c.value.position;
              });
            },
            onHorizontalDragUpdate: (details) {
              if (!_isScrubbing || c == null) return;
              final ratio = details.delta.dx / screenWidth;
              // Полный свайп через экран перематывает на 90 секунд
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
                  InteractiveViewer(
                    transformationController: _transformController,
                    minScale: 0.5,
                    maxScale: 3.5,
                    panEnabled: _videoScale > 1.02,
                    onInteractionUpdate: (_) {
                      final scale = _transformController.value.getMaxScaleOnAxis();
                      if ((scale - _videoScale).abs() > 0.01) {
                        setState(() => _videoScale = scale);
                      }
                    },
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: c.value.aspectRatio,
                        child: VideoPlayer(c),
                      ),
                    ),
                  )
                else
                  const CircularProgressIndicator(color: Color(0xFF6C63FF)),

                // Индикатор свайп-перемотки
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

                // Индикатор двойного тапа ±10 сек
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

                // Оверлей управления
                if (_showControls)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black45,
                      child: SafeArea(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Верхняя панель
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
                                            fontSize: 16,
                                          ),
                                        ),
                                        Text(
                                          '${widget.cartoonTitle} • Серия ${_currentIndex + 1} из ${widget.episodes.length}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _setVideoScale(_videoScale == 1.0 ? 1.35 : 1.0),
                                    icon: const Icon(Icons.aspect_ratio, color: Colors.white, size: 20),
                                    label: Text(
                                      '${(_videoScale * 100).round()}%',
                                      style: const TextStyle(color: Colors.white),
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

                            // Центральные кнопки (изолированное переключение серий внутри мульта)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  iconSize: 40,
                                  tooltip: 'Предыдущая серия этого мульта',
                                  onPressed: hasPrev ? () => _initEpisode(_currentIndex - 1) : null,
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
                                  onPressed: hasNext ? () => _initEpisode(_currentIndex + 1) : null,
                                  icon: Icon(
                                    Icons.skip_next_rounded,
                                    color: hasNext ? Colors.white : Colors.white24,
                                  ),
                                ),
                              ],
                            ),

                            // Нижняя шкала времени и зум-ползунок
                            if (c != null && c.value.isInitialized)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.zoom_in, size: 18, color: Colors.white70),
                                        Expanded(
                                          child: Slider(
                                            value: _videoScale,
                                            min: 0.5,
                                            max: 3.5,
                                            activeColor: const Color(0xFF00D2FF),
                                            onChanged: (v) {
                                              _setVideoScale(v);
                                              _restartHideTimer();
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
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
