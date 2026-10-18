/// 阅读器界面（设计文档 3.3）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../engines/book_engine.dart';
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

  Future<void> _open(Book book, String root) async {
    _engine?.dispose();
    final engine = createEngine(book.format);
    _engine = engine;
    final filePath = p.join(root, book.relativePath);
    try {
      await engine.open(filePath);
      final annotations = await engine.loadAnnotations();
      ref.read(annotationsProvider.notifier).state = annotations;
      // 恢复阅读位置（设计文档 4.2「换设备续读」）
      final position = book.readingPosition?.position;
      if (position != null && position.isNotEmpty) await engine.goTo(position);
      ref.read(readingProgressProvider.notifier).state = engine.getCurrentPosition().percentage;
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

  Future<void> _savePosition(Book book, String root) async {
    final engine = _engine;
    if (engine == null) return;
    final position = engine.getCurrentPosition();
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
    final book = ref.watch(selectedBookProvider);
    final root = ref.watch(libraryRootProvider);
    final progress = ref.watch(readingProgressProvider);
    final annotations = ref.watch(annotationsProvider);

    if (book == null || root == null) {
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
                    onOpen: () => _open(book, root),
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
                  await _savePosition(book, root);
                  setState(() {});
                },
                icon: const Icon(Icons.chevron_left),
                label: const Text('上一页'),
              ),
              Text('${(progress * 100).round()}%', style: Theme.of(context).textTheme.labelLarge),
              FilledButton.icon(
                onPressed: () async {
                  await _engine?.nextPage();
                  await _savePosition(book, root);
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

  /// 各格式的正文文本（PDF / EPUB 的真实渲染在各自的 widget 组件中完成）。
  String _engineBody(BookEngine engine) => switch (engine) {
        TxtEngine() => engine.currentLines().join('\n'),
        MarkdownEngine() => engine.markdown,
        PdfEngine() => '[PDF 渲染区：pdfrx / PDFium FFI]\n\n第 ${engine.currentIndex + 1} 页',
        EpubEngine() => '[EPUB 渲染区：flutter_epub_viewer]\n\n当前章节 ${engine.currentIndex + 1}',
        _ => '不支持的格式',
      };
}
