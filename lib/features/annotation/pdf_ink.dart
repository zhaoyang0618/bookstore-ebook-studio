/// PDF 墨迹层：坐标映射、按页存取、以及页面上的绘制。
///
/// ## 为什么用 `pageOverlaysBuilder` 而不是 `pagePaintCallbacks`
///
/// 最初的实现用 `pagePaintCallbacks` 把墨迹画进 pdfrx 的页面 painter，
/// 结果「画的时候有线，抬笔就消失」。原因是 pdfrx 的
/// `PdfViewer._widgetUpdated()`：
///
/// ```dart
/// if (oldWidget?.documentRef == widget.documentRef) {
///   if (widget.params.doChangesRequireReload(oldWidget?.params)) { ... }
///   return;   // ← 参数不需要 reload 就直接返回，不触发重绘
/// }
/// ```
///
/// 加一笔墨迹不会让参数「需要 reload」，所以 pdfrx 不重绘，
/// 页面 painter 里的回调不会再被调用 —— 笔迹立刻看不见。
///
/// `pageOverlaysBuilder` 返回的 widget 被 pdfrx 用 `Positioned`
/// 精确铺到页面上（见 `pdf_viewer.dart` 的 overlay 组装处），
/// 属于**正常的 Flutter widget 树**，`setState` 即可触发重绘；
/// 缩放、翻页、改窗口也都由框架统一处理。
///
/// ## 坐标系统
///
/// 墨迹统一存 **PDF 页面坐标**（单位：点 = 1/72 英寸，y 向下，
/// 原点在页面左上角）。这与设计文档 1.5 的 `InkPoint` 契约一致，
/// 也正是 `mylibrary` 里 `readerToPdfPoint()` 期望的输入
/// （它在写入时用 `pageSize.height - y` 翻成 PDF 的左下原点）。
///
/// 两处映射：
/// - **捕获**：全屏 InkCanvas 坐标 → 页面坐标（需要页面在屏幕上的矩形）
/// - **绘制**：页面坐标 → 页面浮层局部坐标（浮层原点即页面左上角，无需偏移）
///
/// @module ebook-studio/features/annotation/pdf_ink
library;

import 'package:flutter/material.dart';

import 'ink_canvas.dart';

// ---------- 纯函数：坐标映射 ----------

/// 屏幕坐标 → PDF 页面坐标（捕获用）。
///
/// [pageRect] 是该页在屏幕上的矩形，[pageSize] 是页面的 PDF 尺寸（点）。
Offset screenToPage(Offset screen, Rect pageRect, Size pageSize) {
  if (pageRect.width <= 0 || pageRect.height <= 0) return Offset.zero;
  final nx = (screen.dx - pageRect.left) / pageRect.width;
  final ny = (screen.dy - pageRect.top) / pageRect.height;
  return Offset(nx * pageSize.width, ny * pageSize.height);
}

/// PDF 页面坐标 → 屏幕坐标。
Offset pageToScreen(Offset page, Rect pageRect, Size pageSize) {
  if (pageSize.width <= 0 || pageSize.height <= 0) return pageRect.topLeft;
  final nx = page.dx / pageSize.width;
  final ny = page.dy / pageSize.height;
  return Offset(pageRect.left + nx * pageRect.width, pageRect.top + ny * pageRect.height);
}

/// PDF 页面坐标 → 页面浮层局部坐标（绘制用）。
///
/// 浮层原点就是页面左上角，所以只需按显示比例缩放，不加偏移。
Offset pageToLocal(Offset page, Size displayedSize, Size pageSize) {
  if (pageSize.width <= 0 || pageSize.height <= 0) return Offset.zero;
  return Offset(
    page.dx / pageSize.width * displayedSize.width,
    page.dy / pageSize.height * displayedSize.height,
  );
}

/// 页面浮层局部坐标 → PDF 页面坐标。
Offset localToPage(Offset local, Size displayedSize, Size pageSize) {
  if (displayedSize.width <= 0 || displayedSize.height <= 0) return Offset.zero;
  return Offset(
    local.dx / displayedSize.width * pageSize.width,
    local.dy / displayedSize.height * pageSize.height,
  );
}

/// 屏幕上的一次落点属于哪一页。
///
/// 返回 null 表示落在页面之外（例如页边距区域），此时不应记录笔迹。
PdfPageHit? hitTestPage(List<PdfPageHit> pages, Offset screen) {
  for (final page in pages) {
    if (page.rect.contains(screen)) return page;
  }
  return null;
}

/// 一页在屏幕上的位置与尺寸（`PdfPage` 的轻量快照，便于单测）。
class PdfPageHit {
  const PdfPageHit({
    required this.pageNumber,
    required this.rect,
    required this.size,
  });

  /// 页码，1 起始。
  final int pageNumber;

  /// 屏幕矩形。
  final Rect rect;

  /// PDF 页面尺寸（点）。
  final Size size;
}

// ---------- 绘制 ----------

/// 把一组页面坐标的笔迹画进页面浮层。
///
/// [displayedSize] 是浮层尺寸（即页面显示尺寸），[pageSize] 是 PDF 页面尺寸。
void paintStrokes(
  Canvas canvas,
  List<InkStroke> strokes,
  Size displayedSize,
  Size pageSize,
) {
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;

    // 线宽按显示比例缩放，放大后线也变粗，视觉一致
    final scale = pageSize.width == 0 ? 1.0 : displayedSize.width / pageSize.width;

    Offset toLocal(InkPoint point) => pageToLocal(Offset(point.x, point.y), displayedSize, pageSize);

    if (stroke.points.length == 1) {
      canvas.drawCircle(
        toLocal(stroke.points.first),
        (stroke.width * scale / 2).clamp(0.5, 100.0),
        Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true
          ..blendMode = stroke.isTranslucent ? BlendMode.multiply : BlendMode.srcOver,
      );
      continue;
    }

    final path = Path();
    final first = toLocal(stroke.points.first);
    path.moveTo(first.dx, first.dy);
    for (final point in stroke.points.skip(1)) {
      final local = toLocal(point);
      path.lineTo(local.dx, local.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke.color
        ..strokeWidth = (stroke.width * scale).clamp(0.5, 200.0)
        ..style = PaintingStyle.stroke
        ..strokeCap = stroke.cap
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        // 荧光笔半透明：用 multiply 让底下文字透出来而不是被盖住
        ..blendMode = stroke.isTranslucent ? BlendMode.multiply : BlendMode.srcOver,
    );
  }
}

/// 画已经是浮层局部坐标的笔迹（草稿笔迹用）。
void paintLocalStrokes(Canvas canvas, List<InkStroke> strokes) {
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;

    if (stroke.points.length == 1) {
      canvas.drawCircle(
        Offset(stroke.points.first.x, stroke.points.first.y),
        stroke.width / 2,
        Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true
          ..blendMode = stroke.isTranslucent ? BlendMode.multiply : BlendMode.srcOver,
      );
      continue;
    }

    final path = Path()..moveTo(stroke.points.first.x, stroke.points.first.y);
    for (final point in stroke.points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..style = PaintingStyle.stroke
        ..strokeCap = stroke.cap
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..blendMode = stroke.isTranslucent ? BlendMode.multiply : BlendMode.srcOver,
    );
  }
}

/// 某一页墨迹的绘制器（作为页面浮层里的 CustomPaint）。
class PageInkPainter extends CustomPainter {
  const PageInkPainter({
    required this.strokes,
    required this.pageSize,
    required this.displayedSize,
  });

  /// 该页已落定的墨迹（页面坐标）。
  final List<InkStroke> strokes;

  /// PDF 页面尺寸（点）。
  final Size pageSize;

  /// 页面显示尺寸。
  final Size displayedSize;

  @override
  void paint(Canvas canvas, Size size) => paintStrokes(canvas, strokes, displayedSize, pageSize);

  @override
  bool shouldRepaint(PageInkPainter oldDelegate) =>
      oldDelegate.strokes != strokes ||
      oldDelegate.displayedSize != displayedSize ||
      oldDelegate.pageSize != pageSize;
}

// ---------- 控制器 ----------

/// 按页管理墨迹，并记录各页在屏幕上的位置。
class PdfInkController extends ChangeNotifier {
  /// 页码（1 起始）→ 该页在屏幕上的矩形。
  final Map<int, Rect> _rects = {};

  /// 页码 → 该页的 PDF 尺寸。
  final Map<int, Size> _sizes = {};

  /// 页码 → 该页墨迹（页面坐标）。
  final Map<int, List<InkStroke>> _strokes = {};

  /// 由 `pageOverlaysBuilder` 调用：记录页面布局。
  ///
  /// 刻意**不** notifyListeners —— 它是在 build 期间调用的，
  /// 通知会触发「build 期间 setState」错误。绘制由 CustomPaint 自己负责。
  void recordPageLayout(int pageNumber, Rect rect, Size size) {
    _rects[pageNumber] = rect;
    _sizes[pageNumber] = size;
  }

  /// 各页的屏幕布局快照，供捕获时换算坐标。
  List<PdfPageHit> get hits => _rects.entries
      .where((entry) => _sizes.containsKey(entry.key))
      .map((entry) => PdfPageHit(
            pageNumber: entry.key,
            rect: entry.value,
            size: _sizes[entry.key]!,
          ))
      .toList();

  /// 替换某一页的全部墨迹（打开书时从批注载入）。
  void setPageStrokes(int pageNumber, List<InkStroke> strokes) {
    _strokes[pageNumber] = List.of(strokes);
    notifyListeners();
  }

  /// 追加一笔（页面坐标）。
  void addPageStroke(int pageNumber, InkStroke stroke) {
    (_strokes[pageNumber] ??= <InkStroke>[]).add(stroke);
    notifyListeners();
  }

  /// 撤销某一页的最后一笔。返回是否真的删掉了。
  bool undoPageStroke(int pageNumber) {
    final strokes = _strokes[pageNumber];
    if (strokes == null || strokes.isEmpty) return false;
    strokes.removeLast();
    notifyListeners();
    return true;
  }

  /// 清空某一页的墨迹。
  void clearPage(int pageNumber) {
    if (_strokes.remove(pageNumber) != null) notifyListeners();
  }

  /// 某一页的墨迹（只读快照）。
  List<InkStroke> strokesOf(int pageNumber) => List.unmodifiable(_strokes[pageNumber] ?? const []);

  /// 是否还有墨迹。
  bool get hasStrokes => _strokes.values.any((list) => list.isNotEmpty);

  /// 有墨迹的页数。
  int get inkedPageCount => _strokes.values.where((list) => list.isNotEmpty).length;

  /// 清空所有页（切换书籍时）。
  void clear() {
    _strokes.clear();
    _rects.clear();
    _sizes.clear();
    notifyListeners();
  }
}
