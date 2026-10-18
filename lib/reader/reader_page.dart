/// 阅读器界面（设计文档 3.3）。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../engines/book_engine.dart';
import '../engines/epub_webview.dart';
import '../features/annotation/ink_canvas.dart';
import '../features/annotation/pdf_ink.dart';
import '../pdf/pdf_ink_export.dart';
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

  /// PDF 墨迹层：负责坐标映射与按页存取（见 features/annotation/pdf_ink.dart）。
  final PdfInkController _ink = PdfInkController();

  /// 当前笔型与颜色。
  InkTool _inkTool = InkTool.pen;
  Color _inkColor = kInkPalette.first;

  /// 是否已就「批注存在应用内部目录」提示过（只提示一次，不反复打扰）。
  bool _notesFallbackWarned = false;

  /// 当前批注列表的镜像，避免在回调里读到过期的 provider 值。
  List<Annotation> _annotations = const [];

  @override
  void dispose() {
    _ink.dispose();
    _engine?.dispose();
    super.dispose();
  }

  /// 把批注里的墨迹按页灌入墨迹层，供 pdfrx 绘制回页面。
  void _loadInkFromAnnotations(List<Annotation> annotations) {
    _ink.clear();
    final byPage = <int, List<InkStroke>>{};
    for (final annotation in annotations) {
      if (annotation.type != 'ink' || annotation.strokes == null) continue;
      // 锚点页码按 1 起始存（设计文档 1.5 的 InkAnchor.page 是人类可读页码）
      final page = (annotation.anchor['page'] as num?)?.toInt();
      if (page == null) continue;
      final strokes = byPage.putIfAbsent(page, () => <InkStroke>[]);
      for (final raw in annotation.strokes!) {
        strokes.add(InkStroke.fromJson(raw));
      }
    }
    byPage.forEach(_ink.setPageStrokes);
  }

  /// 把一笔屏幕坐标笔迹转成页面坐标并落盘。
  void _commitInkStroke(InkStroke screenStroke) {
    if (screenStroke.points.isEmpty) return;
    final first = screenStroke.points.first;
    // 找落点所在的页；落在页边距上则忽略
    final hit = hitTestPage(_ink.hits, Offset(first.x, first.y));
    if (hit == null) return;

    final points = <InkPoint>[];
    for (final point in screenStroke.points) {
      final page = screenToPage(Offset(point.x, point.y), hit.rect, hit.size);
      points.add(InkPoint(x: page.dx, y: page.dy, pressure: point.pressure, t: point.t));
    }
    final pageStroke = InkStroke(
      color: screenStroke.color,
      width: screenStroke.width,
      cap: screenStroke.cap,
      points: points,
    );
    _ink.addPageStroke(hit.pageNumber, pageStroke);

    final now = DateTime.now().toUtc().toIso8601String();
    final annotation = Annotation(
      id: 'ink-${DateTime.now().millisecondsSinceEpoch}',
      type: 'ink',
      // 锚点页码 1 起始（与 pdfrx 的 pageNumber 一致）
      anchor: {'type': 'ink', 'page': hit.pageNumber},
      strokes: [pageStroke.toJson()],
      createdAt: now,
      updatedAt: now,
    );
    _annotations = [..._annotations, annotation];
    ref.read(annotationsProvider.notifier).state = _annotations;
    // 手写内容「画完就不能丢」，立即落盘
    unawaited(_persistAnnotations());
    if (mounted) setState(() {});
  }

  /// 当前显示比例（页面点 → 屏幕像素）。取不到时按 1 处理。
  double _currentDisplayScale() {
    final hits = _ink.hits;
    if (hits.isEmpty) return 1;
    final size = hits.first.size;
    if (size.width <= 0) return 1;
    return hits.first.rect.width / size.width;
  }

  /// 当前页的墨迹笔数。
  int _currentPageInkCount() {
    final page = _engine?.currentIndex != null ? (_engine!.currentIndex + 1) : 1;
    return _ink.strokesOf(page).length;
  }

  /// 当前页墨迹对应的批注（按落笔顺序）。
  List<Annotation> _inkAnnotationsOfPage(int page) => _annotations
      .where((a) => a.type == 'ink' && ((a.anchor['page'] as num?)?.toInt() ?? -1) == page)
      .toList();

  /// 撤销当前页的最后一笔。
  void _undoLastStroke() {
    final page = (_engine?.currentIndex ?? 0) + 1;
    if (!_ink.undoPageStroke(page)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前页没有可撤销的笔迹')));
      return;
    }
    // 同步删掉对应的批注：墨迹层与批注列表必须一致，否则重开又回来
    final pageAnnotations = _inkAnnotationsOfPage(page);
    if (pageAnnotations.isNotEmpty) {
      final last = pageAnnotations.last;
      _annotations = _annotations.where((a) => a.id != last.id).toList();
      ref.read(annotationsProvider.notifier).state = _annotations;
    }
    unawaited(_persistAnnotations());
    setState(() {});
  }

  /// 清空当前页墨迹。
  void _clearCurrentPage() {
    final page = (_engine?.currentIndex ?? 0) + 1;
    _ink.clearPage(page);
    _annotations = _annotations
        .where((a) => !(a.type == 'ink' && ((a.anchor['page'] as num?)?.toInt() ?? -1) == page))
        .toList();
    ref.read(annotationsProvider.notifier).state = _annotations;
    unawaited(_persistAnnotations());
    setState(() {});
  }

  /// 把当前页墨迹写成 PDF 原生注释并写回文件。
  ///
  /// 设计文档 3.3 的目标形态：注释成为 PDF 标准对象，
  /// dsh 版（PDF.js）、Acrobat、Preview 都能直接看到。
  Future<void> _exportInkToPdf() async {
    final engine = _engine;
    if (engine is! PdfEngine) return;
    final page = (_engine?.currentIndex ?? 0) + 1;

    // 收集本页墨迹，按批注分组
    final inputs = <InkAnnotationInput>[];
    for (final annotation in _inkAnnotationsOfPage(page)) {
      final strokes = annotation.strokes;
      if (strokes == null || strokes.isEmpty) continue;
      inputs.add(InkAnnotationInput(
        id: annotation.id,
        color: _parseAnnotationColor(annotation),
        strokes: strokes.map(InkStroke.fromJson).toList(),
      ));
    }

    if (inputs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本页没有墨迹可导出')),
        );
      }
      return;
    }

    // 明确告知：这会**修改原 PDF 文件**
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('写入 PDF 原生注释？'),
        content: Text(
          '将把第 $page 页的 ${inputs.length} 条墨迹写成 PDF 标准 /Ink 注释，'
          '并**直接修改**：\n\n${engine.filePath}\n\n'
          '这样其它阅读器（PDF.js / Acrobat / 预览）也能看到笔迹。\n'
          '写入前会自动备份原文件。若系统不允许修改该文件，可以改用「另存为」。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('写入')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = await writeInkIntoPdf(
        pdfPath: engine.filePath,
        pageNumber: page,
        annotations: inputs,
        backupDir: pdfBackupDir,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            '已写入 ${result.annotationCount} 条原生注释（${result.strokeCount} 条笔迹）\n'
            '文件现为 ${(result.bytes / 1024).round()} KB'
            '${result.backupPath != null ? '\n原文件备份：${result.backupPath}' : ''}',
          ),
        ),
      );
    } on PdfInkExportException catch (error) {
      if (!mounted) return;
      // 原地写入被沙箱拒绝时，给一条可行的出路：另存为
      final canSaveAs = error.message.contains('沙箱') || error.message.contains('权限');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 12),
          content: Text('写入失败：${error.message}'),
          action: canSaveAs
              ? SnackBarAction(label: '另存为', onPressed: _saveInkCopyAs)
              : null,
        ),
      );
    } catch (error) {
      // 兜底：任何非预期异常都要让用户看见，不能静默失败
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 12),
          content: Text('写入失败（未预期）：$error'),
        ),
      );
      debugPrint('导出 PDF 注释时出现未预期异常：$error');
    }
  }

  /// 另存为一份带注释的 PDF 副本（用户在保存面板里选位置，
  /// 沙箱会对该位置授权，因此这条路总能走通）。
  Future<void> _saveInkCopyAs() async {
    final engine = _engine;
    if (engine is! PdfEngine) return;
    final page = (_engine?.currentIndex ?? 0) + 1;

    final inputs = <InkAnnotationInput>[];
    for (final annotation in _inkAnnotationsOfPage(page)) {
      final strokes = annotation.strokes;
      if (strokes == null || strokes.isEmpty) continue;
      inputs.add(InkAnnotationInput(
        id: annotation.id,
        color: _parseAnnotationColor(annotation),
        strokes: strokes.map(InkStroke.fromJson).toList(),
      ));
    }
    if (inputs.isEmpty) return;

    final location = await getSaveLocation(
      suggestedName: '${p.basenameWithoutExtension(engine.filePath)}-已标注.pdf',
      acceptedTypeGroups: const [XTypeGroup(label: 'PDF', extensions: ['pdf'])],
    );
    if (location == null || !mounted) return;

    try {
      final result = exportInkAnnotations(
        sourcePath: engine.filePath,
        outputPath: location.path,
        pageNumber: page,
        annotations: inputs,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已另存为：${result.outputPath}')),
      );
    } on PdfInkExportException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('另存失败：${error.message}')),
      );
    }
  }

  /// 从批注里取出颜色（缺省红色）。
  Color _parseAnnotationColor(Annotation annotation) {
    final strokes = annotation.strokes;
    if (strokes == null || strokes.isEmpty) return const Color(0xFFE53935);
    return InkStroke.fromJson(strokes.first).color;
  }

  /// 持久化当前批注列表。
  Future<void> _persistAnnotations() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.saveAnnotations(_annotations);
      // 成功时若用的是退回目录，提示一次位置（避免用户以为批注丢了）
      final location = engine.notesLocation;
      if (!location.besideBook) _warnAboutNotesLocation(location);
    } on FileSystemException catch (error) {
      if (!mounted) return;
      final path = engine.notesPath;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            '批注保存失败：${error.osError?.message ?? error.message}\n'
            '路径：$path\n'
            '${error.osError?.errorCode == 13 ? '权限不足 —— 沙箱不允许写入该目录' : ''}',
          ),
        ),
      );
      debugPrint('批注保存失败：$error\n路径：$path');
    }
  }

  /// 边车被放到应用内部目录时提示一次。
  void _warnAboutNotesLocation(NotesLocation location) {
    if (_notesFallbackWarned) return;
    _notesFallbackWarned = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(location.reason ?? '批注保存在应用内部目录，不随书同步'),
      ),
    );
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
      _annotations = annotations;
      // 墨迹按页恢复（PDF 场景）
      _loadInkFromAnnotations(annotations);

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
          // 手写标注目前只支持 PDF：墨迹锚点是页面坐标（InkAnchor.page），
          // 其它格式没有页面概念，硬画会无处安放。禁用并说明原因，
          // 好过让用户画了半天发现没反应。
          if (_engine is PdfEngine)
            IconButton(
              tooltip: _inkMode ? '退出手写' : '手写标注（PDF）',
              icon: Icon(_inkMode ? Icons.edit_off : Icons.edit),
              onPressed: () => setState(() => _inkMode = !_inkMode),
            )
          else
            IconButton(
              tooltip: '手写标注目前仅支持 PDF',
              icon: const Icon(Icons.edit_off),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('手写标注目前仅支持 PDF —— 墨迹需要页面坐标来锚定')),
                );
              },
            ),
          IconButton(
            tooltip: '批注列表',
            icon: const Icon(Icons.sticky_note_2_outlined),
            onPressed: () => _showAnnotations(context, annotations),
          ),
          if (_engine is PdfEngine)
            IconButton(
              tooltip: '写入 PDF 原生注释',
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: _exportInkToPdf,
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
                    ink: _ink,
                    inkMode: _inkMode,
                  ),
                ),
                // 手写标注层（设计文档 3.3：矢量笔迹）
                if (_inkMode)
                  Positioned.fill(
                    child: InkCanvas(
                      color: _inkColor.withValues(alpha: _inkTool.opacity),
                      width: _inkTool.width,
                      cap: _inkTool.cap,
                      // 草稿线宽按页面显示比例放大，落定后才与之一致
                      displayScale: _currentDisplayScale(),
                      onStrokeEnd: _commitInkStroke,
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
          child: _inkMode
              ? _InkToolbar(
                  tool: _inkTool,
                  color: _inkColor,
                  canUndo: _currentPageInkCount() > 0,
                  onToolChanged: (tool) => setState(() => _inkTool = tool),
                  onColorChanged: (color) => setState(() => _inkColor = color),
                  onUndo: _undoLastStroke,
                  onClearPage: _clearCurrentPage,
                  onDone: () => setState(() => _inkMode = false),
                )
              : Row(
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
                    Text('${(progress * 100).round()}%',
                        style: Theme.of(context).textTheme.labelLarge),
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
  const _EngineView({
    required this.engine,
    required this.book,
    required this.onOpen,
    required this.ink,
    required this.inkMode,
  });

  final BookEngine? engine;
  final Book book;
  final VoidCallback onOpen;

  /// PDF 墨迹层（其它格式用不到，但统一透传保持签名一致）。
  final PdfInkController ink;

  /// 是否处于手写模式。
  final bool inkMode;

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

    // PDF 由 pdfrx（PDFium FFI）原生渲染
    if (engine is PdfEngine) {
      return _PdfSurface(
        engine: engine,
        ink: widget.ink,
        inkMode: widget.inkMode,
        // 页码/页数变化要刷新父级的底栏和进度，不能只 setState 自己
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
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
        _ => '不支持的格式',
      };
}

/// PDF 渲染面：pdfrx 的 PdfViewer，页码变化回写到引擎，墨迹走页面浮层。
class _PdfSurface extends StatefulWidget {
  const _PdfSurface({
    required this.engine,
    required this.ink,
    required this.inkMode,
    required this.onChanged,
  });

  final PdfEngine engine;

  /// 墨迹层：既用于绘制已落定的笔迹，也用于提供页面屏幕矩形。
  final PdfInkController ink;

  /// 是否处于手写模式（手写时屏蔽 pdfrx 的手势，否则画的同时页面会平移）。
  final bool inkMode;

  final VoidCallback onChanged;

  @override
  State<_PdfSurface> createState() => _PdfSurfaceState();
}

class _PdfSurfaceState extends State<_PdfSurface> {
  /// 回调保持同一实例：`PdfViewerParams` 用 == 比较，
  /// 每次 build 新建闭包会被判定为参数变化。
  late final PdfPageOverlaysBuilder _overlaysBuilder = _buildPageOverlays;

  /// 监听墨迹变化，让页面浮层里的 CustomPaint 重绘。
  ///
  /// 注意：pdfrx 只在参数「需要 reload」时才重建页面，
  /// 单纯加一笔墨迹不会触发它的重绘 —— 这正是之前
  /// 「画的时候有线、抬笔就消失」的原因。所以这里用 setState
  /// 驱动**我们自己的**浮层重绘。
  @override
  void initState() {
    super.initState();
    widget.ink.addListener(_onInkChanged);
  }

  @override
  void dispose() {
    widget.ink.removeListener(_onInkChanged);
    super.dispose();
  }

  void _onInkChanged() {
    if (mounted) setState(() {});
  }

  /// 每页的浮层：把该页墨迹画上去。
  ///
  /// pdfrx 会把返回的 widget 用 Positioned 精确铺在页面上，
  /// 所以这里的局部坐标原点就是页面左上角。
  List<Widget> _buildPageOverlays(BuildContext context, Rect pageRect, PdfPage page) {
    final pageSize = Size(page.width, page.height);
    // 记录布局，供全屏捕获层做坐标换算
    widget.ink.recordPageLayout(page.pageNumber, pageRect, pageSize);

    final strokes = widget.ink.strokesOf(page.pageNumber);
    if (strokes.isEmpty) return const [];

    return [
      // 荧光笔要压在文字下面，用 multiply 混合即可；
      // 这里不拦截指针，手势交给 pdfrx 与全屏捕获层。
      IgnorePointer(
        child: CustomPaint(
          painter: PageInkPainter(
            strokes: strokes,
            pageSize: pageSize,
            displayedSize: pageRect.size,
          ),
          size: pageRect.size,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    return AbsorbPointer(
      // 手写模式下屏蔽 pdfrx 的手势：否则画的同时页面会跟着平移。
      // 用 AbsorbPointer 而不是 panEnabled 参数，是因为
      // PdfViewerParams.doChangesRequireReload() 把 panEnabled 算作
      // 「需要 reload」，切换手写模式会重载整个文档。
      absorbing: widget.inkMode,
      child: PdfViewer.file(
        engine.filePath,
        // 换书时重建 viewer：controller 与文件绑定，复用会残留旧文档状态
        key: ValueKey('pdf:${engine.filePath}'),
        controller: engine.controller,
        // 续读：用引擎记下的待跳转页码
        initialPageNumber: engine.resumePage,
        params: PdfViewerParams(
          margin: 8,
          backgroundColor: const Color(0xFFF7F6F3),
          pageOverlaysBuilder: _overlaysBuilder,
          onDocumentChanged: (document) {
            if (document == null) return;
            engine.syncPageCount(document.pages.length);
            widget.onChanged();
          },
          // 页码变化：同步到引擎，驱动底部进度
          onPageChanged: (pageNumber) {
            if (pageNumber == null) return;
            engine.syncCurrentPage(pageNumber);
            widget.onChanged();
          },
        ),
      ),
    );
  }
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

/// 手写工具栏：笔型、颜色、撤销、清空本页。
class _InkToolbar extends StatelessWidget {
  const _InkToolbar({
    required this.tool,
    required this.color,
    required this.canUndo,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onUndo,
    required this.onClearPage,
    required this.onDone,
  });

  final InkTool tool;
  final Color color;
  final bool canUndo;
  final ValueChanged<InkTool> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback onUndo;
  final VoidCallback onClearPage;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // 笔型
        SegmentedButton<InkTool>(
          segments: [
            for (final item in InkTool.values)
              ButtonSegment(
                value: item,
                icon: Icon(_toolIcon(item), size: 18),
                tooltip: item.label,
              ),
          ],
          selected: {tool},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onToolChanged(selection.first),
        ),
        // 颜色
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final swatch in kInkPalette)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: InkWell(
                  onTap: () => onColorChanged(swatch),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: swatch.withValues(alpha: tool.opacity),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: swatch == color ? theme.colorScheme.primary : Colors.black26,
                        width: swatch == color ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        IconButton(
          tooltip: '撤销上一笔',
          icon: const Icon(Icons.undo),
          onPressed: canUndo ? onUndo : null,
        ),
        IconButton(
          tooltip: '清空本页墨迹',
          icon: const Icon(Icons.layers_clear),
          onPressed: onClearPage,
        ),
        FilledButton.icon(
          onPressed: onDone,
          icon: const Icon(Icons.check),
          label: const Text('完成'),
        ),
      ],
    );
  }

  IconData _toolIcon(InkTool tool) => switch (tool) {
        InkTool.pen => Icons.edit,
        InkTool.marker => Icons.brush,
        InkTool.highlighter => Icons.format_color_fill,
      };
}
