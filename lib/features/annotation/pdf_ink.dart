/// PDF 墨迹层：屏幕坐标 ↔ PDF 页面坐标的映射，以及按页存取笔迹。
///
/// ## 为什么需要坐标映射
///
/// 手写笔迹不能以屏幕像素存储，否则：
/// - 缩放 / 改窗口大小后位置全错
/// - 换设备（iPad → Mac）后完全对不上
/// - 无法写进 PDF —— 原生 `/Ink` 注释需要页面坐标系
///
/// 因此笔迹统一存 **PDF 页面坐标**（单位：点，1/72 英寸，y 向下，
/// 原点在页面左上角）。这与设计文档 1.5 的 `InkPoint` 契约一致，
/// 也正是 `mylibrary` 里 `readerToPdfPoint()` 期望的输入
/// （它在写入时用 `pageSize.height - y` 翻成 PDF 的左下原点）。
///
/// ## 屏幕矩形从哪来
///
/// pdfrx 的 `pagePaintCallbacks` 回调签名是
/// `(Canvas canvas, Rect pageRect, PdfPage page)`，
/// 其中 `pageRect` 就是该页当前在屏幕上的矩形。我们用它做双向换算，
/// 同时顺便把该页已有的墨迹画上去（天然对齐，不需要自己算缩放平移）。
///
/// @module ebook-studio/features/annotation/pdf_ink
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ink_canvas.dart';

/// 屏幕坐标 → PDF 页面坐标。
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

/// 屏幕上的一次落点属于哪一页。
///
/// 返回 null 表示落在页面之外（例如页边距区域），此时不应记录笔迹。
/// 调用方拿返回值里的 `rect` / `size` 做坐标换算。
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

/// 把一组页面坐标的笔迹画到 [canvas] 上。
///
/// [pageRect] / [pageSize] 给出该页当前的屏幕映射。
void paintStrokes(
  ui.Canvas canvas,
  List<InkStroke> strokes,
  Rect pageRect,
  Size pageSize,
) {
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    final paint = Paint()
      ..color = stroke.color
      // 笔宽随页面缩放，这样放大后线也变粗，视觉一致
      ..strokeWidth = stroke.width * (pageRect.width / (pageSize.width == 0 ? 1 : pageSize.width))
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    Offset toScreen(InkPoint point) => pageToScreen(Offset(point.x, point.y), pageRect, pageSize);

    if (stroke.points.length == 1) {
      // 单点轻点也留痕迹
      canvas.drawCircle(toScreen(stroke.points.first), paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
      continue;
    }

    final path = Path();
    final first = toScreen(stroke.points.first);
    path.moveTo(first.dx, first.dy);
    for (final point in stroke.points.skip(1)) {
      final screen = toScreen(point);
      path.lineTo(screen.dx, screen.dy);
    }
    canvas.drawPath(path, paint);
  }
}

/// 按页管理墨迹，并负责与 pdfrx 的绘制回调对接。
class PdfInkController extends ChangeNotifier {
  /// 页码（1 起始）→ 该页在屏幕上的矩形。
  final Map<int, Rect> _rects = {};

  /// 页码 → 该页的 PDF 尺寸。
  final Map<int, Size> _sizes = {};

  /// 页码 → 该页墨迹（页面坐标）。
  final Map<int, List<InkStroke>> _strokes = {};

  /// 一页的屏幕布局快照，供捕获时换算。
  List<PdfPageHit> get hits => _rects.entries
      .where((entry) => _sizes.containsKey(entry.key))
      .map((entry) => PdfPageHit(
            pageNumber: entry.key,
            rect: entry.value,
            size: _sizes[entry.key]!,
          ))
      .toList();

  /// 由 `PdfViewerParams.pagePaintCallbacks` 调用。
  ///
  /// 每次重绘都会刷新页面矩形，并把该页已有墨迹画上去——
  /// 由 pdfrx 提供正确的缩放/平移，我们不必自己算。
  void paintPage(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    _rects[page.pageNumber] = pageRect;
    final size = Size(page.width, page.height);
    _sizes[page.pageNumber] = size;

    final strokes = _strokes[page.pageNumber];
    if (strokes == null || strokes.isEmpty) return;
    paintStrokes(canvas, strokes, pageRect, size);
  }

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

  /// 某一页的墨迹（只读快照）。
  List<InkStroke> strokesOf(int pageNumber) => List.unmodifiable(_strokes[pageNumber] ?? const []);

  /// 是否有任何墨迹。
  bool get hasStrokes => _strokes.values.any((list) => list.isNotEmpty);

  /// 清空所有页（切换书籍时）。
  void clear() {
    _strokes.clear();
    _rects.clear();
    _sizes.clear();
    notifyListeners();
  }
}
