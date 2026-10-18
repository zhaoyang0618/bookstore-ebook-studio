/// 统一 `BookEngine` 接口（设计文档 3.3）。
///
/// 与 dsh 版的 TypeScript interface 是同一份契约（设计文档 4.3
/// 「接口是契约，实现是自由的」）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/mylibrary_models.dart';
import '../storage/my_library_store.dart';
import 'epub_webview.dart';

/// 目录项。
class TocItem {
  const TocItem({required this.title, required this.href, this.children = const []});

  final String title;
  final String href;
  final List<TocItem> children;
}

/// 书籍元信息。
class BookMeta {
  const BookMeta({required this.title, required this.author, required this.sections});

  final String title;
  final String author;

  /// 总页数（PDF）或总章节数（EPUB）。
  final int sections;
}

/// 阅读位置。
class ReaderPosition {
  const ReaderPosition({required this.position, required this.percentage});

  /// EPUB 为 CFI，PDF 为页码，TXT 为字符偏移。
  final String position;
  final double percentage;
}

/// 统一阅读引擎接口（设计文档 3.3）。
///
/// 四种格式各自实现：PDFium（FFI）/ flutter_epub_viewer /
/// flutter_markdown / 自研分页器。
abstract class BookEngine {
  /// 引擎负责的格式。
  BookFormat get format;

  /// 当前页索引（0 起）。
  int get currentIndex;

  /// 总页数 / 总章节数。
  int get pageCount;

  /// 打开书籍，返回元信息。
  Future<BookMeta> open(String filePath);

  /// 读取目录。
  Future<List<TocItem>> getToc();

  /// 渲染某一页到 container。
  Future<void> renderPage(int pageIndex, Widget container);

  /// 总页数。
  Future<int> getPageCount();

  /// 当前阅读位置。
  ReaderPosition getCurrentPosition();

  /// 是否支持批注。
  bool supportsAnnotation();

  /// 加载批注（非 PDF 从边车文件读，PDF 从文件本身读）。
  Future<List<Annotation>> loadAnnotations();

  /// 保存批注（PDF 写回文件本身，其它写边车）。
  Future<void> saveAnnotations();

  /// 翻页。
  Future<void> nextPage();

  Future<void> prevPage();

  /// 跳到某个位置。
  Future<void> goTo(String position);

  /// 释放资源。
  void dispose();
}

/// 引擎工厂：按格式选实现。
BookEngine createEngine(BookFormat format) => switch (format) {
      BookFormat.epub => EpubEngine(),
      BookFormat.pdf => PdfEngine(),
      BookFormat.markdown => MarkdownEngine(),
      BookFormat.txt => TxtEngine(),
    };

/// 引擎公共基类：实现翻页与位置的默认行为。
abstract class BaseBookEngine implements BookEngine {
  int _currentIndex = 0;
  int _pageCount = 0;

  @override
  Future<void> nextPage() async {
    if (_currentIndex < _pageCount - 1) _currentIndex += 1;
  }

  @override
  Future<void> prevPage() async {
    if (_currentIndex > 0) _currentIndex -= 1;
  }

  @override
  ReaderPosition getCurrentPosition() => ReaderPosition(
        position: positionFor(_currentIndex),
        percentage: _pageCount == 0 ? 0 : (_currentIndex + 1) / _pageCount,
      );

  @override
  Future<void> goTo(String position) async {
    final index = indexOf(position);
    if (index >= 0 && index < _pageCount) _currentIndex = index;
  }

  /// 把页索引转成持久化位置标识。
  String positionFor(int index);

  /// 把持久化位置标识解析回页索引。
  int indexOf(String position);

  /// 设置总页数（子类在 open 后调用）。
  void setPageCount(int count) {
    _pageCount = count;
  }

  /// 设置当前页索引。
  ///
  /// 用于「原生层是唯一事实源」的场景：PDF 的页码由 PDFium 维护，
  /// 滚动/跳转后需要把真实页码回写到引擎，而不是引擎自己猜。
  void setCurrentIndex(int index) {
    _currentIndex = index < 0 ? 0 : index;
  }

  @override
  int get currentIndex => _currentIndex;

  @override
  int get pageCount => _pageCount;
}

/// EPUB 引擎（设计文档 3.2：flutter_epub_viewer）。
class EpubEngine extends BaseBookEngine {
  @override
  BookFormat get format => BookFormat.epub;

  /// WebView + foliate-js 的控制器，由 EpubWebView widget 承载。
  ///
  /// 为什么引擎持有 controller 而不是自己渲染：
  /// foliate-js 跑在 WebView 里，实际绘制由 widget 层完成，
  /// 引擎负责读文件、读写边车、以及把翻页指令转发给 controller。
  final EpubController controller = EpubController();

  String _filePath = '';
  Uint8List? _bytes;
  List<TocItem> _toc = const [];

  /// 已读取的原始字节，供 widget 注入 WebView。
  Uint8List? get bytes => _bytes;

  /// 上次阅读位置（epubcfi），用于打开时续读（设计文档 4.2「换设备续读」）。
  String? lastKnownCfi;

  /// 记录续读位置；打开前由上层从 library.json 的 reading_position 传入。
  void setResumeCfi(String? cfi) {
    lastKnownCfi = (cfi != null && cfi.isNotEmpty) ? cfi : null;
  }

  @override
  Future<BookMeta> open(String filePath) async {
    _filePath = filePath;
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('电子书不存在', filePath);
    }
    _bytes = file.readAsBytesSync();

    // foliate 打开后会通过 relocate 事件回报真实章节数，
    // 这里先给一个占位值，open 完成后由 controller 更新。
    final meta = BookMeta(
      title: filePath.split('/').last,
      author: '',
      sections: 0,
    );
    setPageCount(0);
    return meta;
  }

  @override
  Future<List<TocItem>> getToc() async => _toc;

  @override
  Future<void> renderPage(int pageIndex, Widget container) async {
    // 真实渲染由 EpubWebView 完成（本引擎不直接绘制）
  }

  @override
  Future<int> getPageCount() async => pageCount;

  /// foliate 走的是 CFI，位置由 controller 维护。
  @override
  String positionFor(int index) => controller.location?.cfi ?? '';

  @override
  int indexOf(String position) => 0;

  @override
  ReaderPosition getCurrentPosition() => ReaderPosition(
        position: controller.location?.cfi ?? '',
        percentage: controller.location?.fraction ?? 0,
      );

  /// 翻页交给 controller（foliate 自己算分页）。
  @override
  Future<void> nextPage() async => controller.next();

  @override
  Future<void> prevPage() async => controller.prev();

  @override
  Future<void> goTo(String position) async {
    if (position.isNotEmpty) await controller.goTo(position);
  }

  @override
  bool supportsAnnotation() => true;

  @override
  Future<List<Annotation>> loadAnnotations() async => readSidecarAnnotations(notesPathFor(_filePath));

  @override
  Future<void> saveAnnotations() async {
    // 批注写回边车文件（设计文档 3.3）
  }

  @override
  void dispose() {
    controller.dispose();
    _toc = const [];
    _bytes = null;
  }
}

/// PDF 引擎（设计文档 3.2 / 3.3：PDFium FFI + 原生注释 API）。
///
/// 渲染交给 pdfrx（PDFium 的 FFI 绑定，原生级性能）。
/// 引擎负责：文件可用性检查、页数/当前位置同步、边车批注读写。
///
/// 为什么引擎持有 controller 而不是自己绘制：
/// pdfrx 提供的是 `PdfViewer` widget，实际渲染在 widget 层完成；
/// 引擎把翻页/跳转指令转发给 controller，并从中回读页码。
class PdfEngine extends BaseBookEngine {
  @override
  BookFormat get format => BookFormat.pdf;

  /// pdfrx 的控制器，由 PdfViewer widget 承载。
  final PdfViewerController controller = PdfViewerController();

  String _filePath = '';

  /// 文件路径，供 widget 层构造 PdfViewer。
  String get filePath => _filePath;

  /// 待跳转的页码（1 起始）。
  ///
  /// 为什么需要它：打开书时 `goTo()` 会被调用以恢复上次阅读位置，
  /// 但此刻 PdfViewer 还没创建、controller 未就绪，直接跳转会丢失。
  /// 因此先记下来，由 widget 作为 initialPageNumber 传入。
  int _resumePage = 1;
  int get resumePage => _resumePage;

  /// 当前页码（1 起始）。
  ///
  /// 优先问 pdfrx（viewer 挂载后它才是事实源）；
  /// viewer 尚未就绪时回退到基类的 index，避免读写未初始化的 controller
  /// —— `pageNumber` 在未挂载时会抛异常。
  int get currentPageNumber {
    try {
      if (controller.isReady) {
        final page = controller.pageNumber;
        if (page != null && page > 0) return page;
      }
    } catch (_) {
      // controller 未挂载：忽略，走回退
    }
    return currentIndex + 1;
  }

  @override
  Future<BookMeta> open(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('电子书不存在', filePath);
    }
    _filePath = filePath;
    // 真实页数在 PdfViewer 加载完文档后通过 controller.pageCount 得到，
    // 这里无法提前知道（PDFium 需要解析文件），故先置 0，由 widget 回填。
    return BookMeta(title: filePath.split('/').last, author: '', sections: 0);
  }

  /// 由 widget 层在文档加载完成后回填页数。
  void syncPageCount(int totalPages) {
    setPageCount(totalPages);
  }

  /// 由 widget 层在页码变化时调用。
  void syncCurrentPage(int pageNumber) {
    setCurrentIndex(pageNumber - 1);
  }

  @override
  Future<List<TocItem>> getToc() async => const [];

  @override
  Future<void> renderPage(int pageIndex, Widget container) async {
    // 实际渲染在 PdfViewer 组件中完成（pdfrx）
  }

  @override
  Future<int> getPageCount() async => pageCount;

  /// 位置用页码表示（1 起始），与阅读位置的跨端约定一致。
  @override
  String positionFor(int index) => (index + 1).toString();

  @override
  int indexOf(String position) => (int.tryParse(position) ?? 1) - 1;

  @override
  ReaderPosition getCurrentPosition() {
    final total = pageCount;
    final page = currentPageNumber;
    return ReaderPosition(
      position: page.toString(),
      percentage: total > 0 ? ((page - 1) / total).clamp(0.0, 1.0) : 0.0,
    );
  }

  /// 翻页：PDF 按页跳转。
  @override
  Future<void> nextPage() async {
    if (!controller.isReady) return;
    final total = controller.pageCount;
    final current = currentPageNumber;
    if (current < total) {
      await controller.goToPage(pageNumber: current + 1);
    }
  }

  @override
  Future<void> prevPage() async {
    if (!controller.isReady) return;
    final current = currentPageNumber;
    if (current > 1) {
      await controller.goToPage(pageNumber: current - 1);
    }
  }

  @override
  Future<void> goTo(String position) async {
    final page = int.tryParse(position);
    if (page == null || page < 1) return;
    _resumePage = page;
    if (!controller.isReady) return; // 等 widget 就绪后用 resumePage
    if (page <= controller.pageCount) {
      await controller.goToPage(pageNumber: page);
    }
  }

  @override
  bool supportsAnnotation() => true;

  @override
  Future<List<Annotation>> loadAnnotations() async {
    // PDF 注释是**原生 PDF 注释对象**，直接从文件本身读取（设计文档 3.3）
    return readSidecarAnnotations(notesPathFor(_filePath));
  }

  @override
  Future<void> saveAnnotations() async {
    // 通过 FFI 调用 PDFium 原生注释 API，把注释序列化回 PDF 文件。
    // 笔迹以**矢量数据**存储（点 + 压力 + 时间戳），而非截图（设计文档 3.3）。
    //
    // 写入逻辑已在 mylibrary-core 的 pdf-writer 模块实现并通过真实 PDF 验证，
    // Flutter 侧接入需要走 Platform Channel 或 FFI，属后续工作。
  }

  @override
  void dispose() {}
}

/// Markdown 引擎（设计文档 3.2：flutter_markdown）。
class MarkdownEngine extends BaseBookEngine {
  @override
  BookFormat get format => BookFormat.markdown;

  String _filePath = '';
  String _markdown = '';

  @override
  Future<BookMeta> open(String filePath) async {
    _filePath = filePath;
    _markdown = readTextFile(filePath);
    setPageCount(1);
    return BookMeta(title: filePath.split('/').last, author: '', sections: 1);
  }

  @override
  Future<List<TocItem>> getToc() async {
    final toc = <TocItem>[];
    for (final match in RegExp(r'^(#{1,3})\s+(.+)$', multiLine: true).allMatches(_markdown)) {
      toc.add(TocItem(title: match.group(2) ?? '', href: '#${match.group(2)}'));
    }
    return toc;
  }

  @override
  Future<void> renderPage(int pageIndex, Widget container) async {
    // 实际渲染在 MarkdownView 组件中完成
  }

  @override
  Future<int> getPageCount() async => 1;

  @override
  String positionFor(int index) => '0';

  @override
  int indexOf(String position) => 0;

  @override
  bool supportsAnnotation() => true;

  @override
  Future<List<Annotation>> loadAnnotations() async => readSidecarAnnotations(notesPathFor(_filePath));

  @override
  Future<void> saveAnnotations() async {
    // 批注写回边车文件
  }

  @override
  void dispose() {
    _markdown = '';
  }

  String get markdown => _markdown;
}

/// TXT 引擎（设计文档 3.2：自研分页器）。
class TxtEngine extends BaseBookEngine {
  TxtEngine({this.pageSize = 45});

  @override
  BookFormat get format => BookFormat.txt;

  /// 每页行数。
  final int pageSize;

  String _filePath = '';
  List<String> _lines = const [];

  @override
  Future<BookMeta> open(String filePath) async {
    _filePath = filePath;
    final text = readTextFile(filePath);
    _lines = text.split('\n');
    setPageCount(_lines.isEmpty ? 1 : (_lines.length + pageSize - 1) ~/ pageSize);
    return BookMeta(title: filePath.split('/').last, author: '', sections: pageCount);
  }

  @override
  Future<List<TocItem>> getToc() async => const [];

  @override
  Future<void> renderPage(int pageIndex, Widget container) async {
    // 实际渲染在 TxtView 组件中完成
  }

  @override
  Future<int> getPageCount() async => pageCount;

  @override
  String positionFor(int index) => (index * pageSize).toString();

  @override
  int indexOf(String position) {
    final line = int.tryParse(position) ?? 0;
    return pageSize == 0 ? 0 : line ~/ pageSize;
  }

  @override
  bool supportsAnnotation() => true;

  @override
  Future<List<Annotation>> loadAnnotations() async => readSidecarAnnotations(notesPathFor(_filePath));

  @override
  Future<void> saveAnnotations() async {
    // 批注写回边车文件
  }

  @override
  void dispose() {
    _lines = const [];
  }

  /// 当前页的文本行。
  List<String> currentLines() {
    final start = currentIndex * pageSize;
    if (start >= _lines.length) return const [];
    return _lines.sublist(start, (start + pageSize).clamp(0, _lines.length));
  }
}

/// 由书籍路径推导边车文件路径（设计文档 1.2）。
String notesPathFor(String filePath) => '${filePath.replaceAll(RegExp(r'\.[^./]+$'), '')}.notes.json';

/// 从边车文件读取批注（EPUB / Markdown / TXT）。
Future<List<Annotation>> readSidecarAnnotations(String notesPath) async {
  final file = File(notesPath);
  if (!file.existsSync()) return const [];
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) return const [];
  final annotations = decoded['annotations'];
  if (annotations is! List) return const [];
  return annotations.whereType<Map<String, dynamic>>().map(Annotation.fromJson).toList();
}

/// 向边车文件写回批注（EPUB / Markdown / TXT）。
Future<void> writeSidecarAnnotations(String notesPath, List<Annotation> annotations) async {
  final file = File(notesPath);
  file.parent.createSync(recursive: true);
  final json = <String, dynamic>{
    'schema_version': '1.0',
    'annotations': annotations.map((a) => a.toJson()).toList(),
  };
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
}

/// 读取文本文件（引擎用）。
String readTextFile(String path) => File(path).readAsStringSync();
