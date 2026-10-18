/// 阅读器界面（设计文档 3.3）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../engines/book_engine.dart';
import '../engines/epub_webview.dart';
import '../features/annotation/ink_canvas.dart';
import '../features/annotation/annotation_panel.dart';
import '../library/library_page.dart';
import '../models/mylibrary_models.dart';
import '../storage/my_library_store.dart';

/// 当前阅读进度（0 ~ 1）。
final readingProgressProvider = StateProvider<double>((ref) => 0);

/// 当前书的批注。
final annotationsProvider = StateProvider<List<Annotation>>((ref) => const []);

/// 阅读器界面。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key});

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  BookEngine? _engine;
  bool _inkMode = false;

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  /// 打开一本书。`root` 为 null 表示「独立文件」模式（不经 MyLibrary）。
  Future<void> _open(Book book, String? root) async {
    _engine?.dispose();
    final engine = createEngine(book.format);
    _engine = engine;
    final filePath = root == null ? book.relativePath : p.join(root, book.relativePath);
    try {
      await engine.open(filePath);
      final annotations = await engine.loadAnnotations();
      ref.read(annotationsProvider.notifier).state = annotations;

      // EPUB 走 foliate：续读位置通过 CFI 传给 WebView
      if (engine is EpubEngine) {
        engine.setResumeCfi(book.readingPosition?.position);
      } else {
        // 恢复阅读位置（设计文档 4.2「换设备续读」）
        final position = book.readingPosition?.position;
        if (position != null && position.isNotEmpty) await engine.goTo(position);
      }
      ref.read(readingProgressProvider.notifier).state = engine.getCurrentPosition().percentage;

      // EPUB 的进度由 foliate 的 relocate 事件驱动
      if (engine is EpubEngine) {
        engine.controller.onLocation.listen((location) {
          if (!mounted) return;
          ref.read(readingProgressProvider.notifier).state = location.fraction;
          setState(() {});
        });
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开失败：${error.message}')));
      }
    } on MyLibraryException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('打开失败：${error.message}')));
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _savePosition(Book book, String? root) async {
    final engine = _engine;
    if (engine == null) return;
    final position = engine.getCurrentPosition();
    ref.read(readingProgressProvider.notifier).state = position.percentage;
    // 独立文件没有 library.json 可写，进度只留在内存里
    if (root == null) return;
    final store = MyLibraryStore(root, clientId: 'flutter-app-client');
    store.updateBook(book.id, (current) => Book(
          id: current.id,
          title: current.title,
          author: current.author,
          format: current.format,
          relativePath: current.relativePath,
          coverPath: current.coverPath,
          notesPath: current.notesPath,
          recordingsDir: current.recordingsDir,
          sizeBytes: current.sizeBytes,
          fileHash: current.fileHash,
          addedAt: current.addedAt,
          syncState: current.syncState,
          heldBy: current.heldBy,
          readingPosition: ReadingPosition(
            position: position.position,
            percentage: position.percentage,
            updatedAt: DateTime.now().toUtc().toIso8601String(),
            updatedBy: 'flutter-app-client',
          ),
          tags: current.tags,
          collections: current.collections,
          linkedWikiPages: current.linkedWikiPages,
        ));
    ref.read(readingProgressProvider.notifier).state = position.percentage;
  }

  @override
  Widget build(BuildContext context) {
    final libraryBook = ref.watch(selectedBookProvider);
    final root = ref.watch(libraryRootProvider);
    final standalonePath = ref.watch(standaloneFileProvider);
    final progress = ref.watch(readingProgressProvider);
    final annotations = ref.watch(annotationsProvider);

    // 独立文件优先：用户刚用「直接打开一本书」选的
    final Book? book = standalonePath != null
        ? _bookFromStandalonePath(standalonePath)
        : libraryBook;

    if (book == null) {
      return const Scaffold(body: Center(child: Text('从图书馆选择一本书，或用「直接打开一本书」选择文件')));
    }
    final effectiveRoot = standalonePath != null ? null : root;
    if (standalonePath == null && effectiveRoot == null) {
      return const Scaffold(body: Center(child: Text('从图书馆选择一本书开始阅读')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${book.title} · ${book.author}'),
        actions: [
          IconButton(
            tooltip: _inkMode ? '退出手写' : '手写标注',
            icon: Icon(_inkMode ? Icons.edit_off : Icons.edit),
            onPressed: () => setState(() => _inkMode = !_inkMode),
          ),
          IconButton(
            tooltip: '批注列表',
            icon: const Icon(Icons.sticky_note_2_outlined),
            onPressed: () => _showAnnotations(context, annotations),
          ),
        ],
      ),
      body: Column(
        children: [
          LinearProgressIndicator(value: progress, minHeight: 3),
          Expanded(
            child: Stack(
              children: [
                // 阅读区：由引擎负责渲染（PDF / EPUB / Markdown / TXT）
                Positioned.fill(
                  child: _EngineView(
                    engine: _engine,
                    book: book,
                    onOpen: () => _open(book, effectiveRoot),
                  ),
                ),
                // 手写标注层（设计文档 3.3：矢量笔迹）
                if (_inkMode)
                  Positioned.fill(
                    child: InkCanvas(
                      onStrokeEnd: (stroke) {
                        final annotation = Annotation(
                          id: 'ink-${DateTime.now().millisecondsSinceEpoch}',
                          type: 'ink',
                          anchor: {'type': 'ink', 'page': _engine?.currentIndex ?? 0},
                          strokes: [stroke.toJson()],
                          createdAt: DateTime.now().toUtc().toIso8601String(),
                          updatedAt: DateTime.now().toUtc().toIso8601String(),
                        );
                        ref.read(annotationsProvider.notifier).state = [...annotations, annotation];
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await _engine?.prevPage();
                  await _savePosition(book, effectiveRoot);
                  setState(() {});
                },
                icon: const Icon(Icons.chevron_left),
                label: const Text('上一页'),
              ),
              Text('${(progress * 100).round()}%', style: Theme.of(context).textTheme.labelLarge),
              FilledButton.icon(
                onPressed: () async {
                  await _engine?.nextPage();
                  await _savePosition(book, effectiveRoot);
                  setState(() {});
                },
                icon: const Icon(Icons.chevron_right),
                label: const Text('下一页'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 由独立文件路径构造一个临时 Book（不写入 library.json）。
  Book _bookFromStandalonePath(String path) {
    final name = p.basename(path);
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    final format = switch (ext) {
      'epub' => BookFormat.epub,
      'pdf' => BookFormat.pdf,
      'md' || 'markdown' => BookFormat.markdown,
      _ => BookFormat.txt,
    };
    return Book(
      id: 'standalone:$path',
      title: p.basenameWithoutExtension(path),
      author: name,
      format: format,
      relativePath: path,
      sizeBytes: 0,
      addedAt: DateTime.now().toUtc().toIso8601String(),
      syncState: const BookSyncState(
        metadata: SyncState.localOnly,
        cover: SyncState.missing,
        notes: SyncState.localOnly,
        file: SyncState.localOnly,
        recordings: SyncState.missing,
      ),
      heldBy: const [],
    );
  }

  void _showAnnotations(BuildContext context, List<Annotation> annotations) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => AnnotationPanel(annotations: annotations),
    );
  }
}

/// 引擎视图：根据格式分派到具体渲染组件。
class _EngineView extends StatefulWidget {
  const _EngineView({required this.engine, required this.book, required this.onOpen});

  final BookEngine? engine;
  final Book book;
  final VoidCallback onOpen;

  @override
  State<_EngineView> createState() => _EngineViewState();
}

class _EngineViewState extends State<_EngineView> {
  @override
  void initState() {
    super.initState();
    if (widget.engine == null) {
      // 引擎尚未创建：等首帧布局完成后再创建，避免在 build 期间触发 setState
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onOpen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    if (engine == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // EPUB 由 foliate-js 在 WebView 里渲染
    if (engine is EpubEngine) {
      return _EpubSurface(engine: engine);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(_engineBody(engine)),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '第 ${engine.currentIndex + 1} 页 / 共 ${engine.pageCount == 0 ? '?' : engine.pageCount} 页',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    );
  }

  /// 各格式的正文文本（PDF 的真实渲染在 PdfView 组件中完成）。
  String _engineBody(BookEngine engine) => switch (engine) {
        TxtEngine() => engine.currentLines().join('\n'),
        MarkdownEngine() => engine.markdown,
        PdfEngine() => '[PDF 渲染区：pdfrx / PDFium FFI]\n\n第 ${engine.currentIndex + 1} 页',
        _ => '不支持的格式',
      };
}

/// EPUB 渲染面：把引擎读到的字节注入 WebView，并显示加载/错误状态。
class _EpubSurface extends StatefulWidget {
  const _EpubSurface({required this.engine});

  final EpubEngine engine;

  @override
  State<_EpubSurface> createState() => _EpubSurfaceState();
}

class _EpubSurfaceState extends State<_EpubSurface> {
  bool _injected = false;

  @override
  void initState() {
    super.initState();
    // 桥就绪后再注入；同时监听错误
    widget.engine.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.engine.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// 桥就绪且拿到字节后注入一次。
  void _maybeInject() {
    if (_injected) return;
    final controller = widget.engine.controller;
    final bytes = widget.engine.bytes;
    if (!controller.bridgeReady || bytes == null) return;
    _injected = true;
    final cfi = widget.engine.lastKnownCfi;
    unawaited(controller.openBytes(bytes, initialCfi: cfi));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.engine.controller;
    _maybeInject();

    return Stack(
      children: [
        Positioned.fill(child: EpubWebView(controller: controller)),
        // 错误面板：把 WebView 里的失败原因显示出来，便于诊断
        if (controller.state == EpubBridgeState.failed && controller.lastError != null)
          Positioned.fill(
            child: Container(
              color: const Color(0xFFFFF5F5),
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: SelectableText(
                  '电子书打开失败\n\n${controller.lastError}',
                  style: const TextStyle(color: Color(0xFF7F1D1D), fontSize: 13, height: 1.7),
                ),
              ),
            ),
          ),
        if (controller.state == EpubBridgeState.loading)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0xFFF7F6F3),
              child: Center(child: Text('正在打开电子书…')),
            ),
          ),
      ],
    );
  }
}
