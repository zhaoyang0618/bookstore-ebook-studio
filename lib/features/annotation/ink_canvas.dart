/// 手写标注层（设计文档 3.2 / 3.3）。
///
/// 用 `CustomPainter` 绘制笔迹，以**矢量形式**存储（点 + 压力 + 时间戳），
/// 而非截图（设计文档 3.3）。
///
/// ## 职责边界
///
/// 本组件只负责**捕获当前这一笔并在屏幕上实时跟手**。
/// 已经落定的笔迹由 `PdfInkController` 通过 pdfrx 的页面绘制回调
/// 画到页面上（见 `pdf_ink.dart`）——这样缩放、翻页、滚动时
/// 笔迹始终贴着页面，不需要我们自己算变换矩阵。
///
/// ## 输入设备
///
/// 支持 `mouse` / `trackpad` / `touch` / `stylus`。
/// 桌面端（macOS / Windows / Linux）用鼠标或触控板即可书写；
/// 平板端用手写笔，压力值真实来自硬件。
///
/// @module ebook-studio/features/annotation/ink_canvas
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// 一笔的矢量数据（与笔记边车的 strokes 结构一致，设计文档 1.5）。
///
/// 坐标含义由调用方决定：PDF 场景下是**页面坐标**（点，y 向下，原点左上）。
class InkStroke {
  InkStroke({required this.color, required this.width, List<InkPoint>? points}) : points = points ?? [];

  final Color color;
  final double width;
  final List<InkPoint> points;

  /// 序列化为边车 JSON 里的形状（与 TS 侧 `InkStroke` 契约一致）。
  Map<String, dynamic> toJson() => {
        'points': points.map((point) => point.toJson()).toList(),
        'color': '#${_hex(color)}',
        'width': width,
      };

  /// 从边车 JSON 还原。
  static InkStroke fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    final points = <InkPoint>[];
    if (rawPoints is List) {
      for (final item in rawPoints) {
        if (item is Map) {
          points.add(InkPoint.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return InkStroke(
      color: _parseColor(json['color']),
      width: (json['width'] as num?)?.toDouble() ?? 2,
      points: points,
    );
  }

  static String _hex(Color color) =>
      color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2);

  static Color _parseColor(Object? value) {
    if (value is! String) return const Color(0xFFFF0000);
    final hex = value.replaceFirst('#', '');
    final rgb = hex.length == 8 ? hex.substring(2) : hex;
    if (rgb.length != 6) return const Color(0xFFFF0000);
    final parsed = int.tryParse(rgb, radix: 16);
    return parsed == null ? const Color(0xFFFF0000) : Color(0xFF000000 | parsed);
  }
}

/// 笔迹中的一个点。
class InkPoint {
  InkPoint({required this.x, required this.y, this.pressure = 1, this.t = 0});

  final double x;
  final double y;

  /// 压感（0 ~ 1）。鼠标没有压感，统一记 1。
  final double pressure;

  /// 相对笔迹起点的毫秒数。
  final int t;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'pressure': pressure, 't': t};

  static InkPoint fromJson(Map<String, dynamic> json) => InkPoint(
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        pressure: (json['pressure'] as num?)?.toDouble() ?? 1,
        t: (json['t'] as num?)?.toInt() ?? 0,
      );
}

/// 手写标注画布。
///
/// 只绘制**进行中的那一笔**；已完成笔迹由外部（pdfrx 页面回调）负责绘制。
class InkCanvas extends StatefulWidget {
  const InkCanvas({
    required this.onStrokeEnd,
    this.color = const Color(0xFFE53935),
    this.width = 2,
    super.key,
  });

  /// 一笔结束时的回调，返回**屏幕坐标**的笔迹。
  final void Function(InkStroke stroke) onStrokeEnd;

  final Color color;
  final double width;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  InkStroke? _current;
  DateTime? _strokeStart;

  /// 只接受指针类事件；滚轮/悬停不参与书写。
  bool _isDrawingDevice(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse ||
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      kind == PointerDeviceKind.trackpad;

  /// 取压感值。鼠标 / 触控板没有压感，统一给 1，避免笔迹被画得过细。
  double _pressureOf(PointerEvent event) {
    final pressure = event.pressure;
    if (pressure <= 0) return 1;
    return pressure.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 用 Listener 而非 GestureDetector：拿到原始指针事件，
      // 不做手势竞争判定，落笔即画，延迟最低。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (!_isDrawingDevice(event.kind)) return;
        if (_current != null) return;
        _strokeStart = DateTime.now();
        _current = InkStroke(
          color: widget.color,
          width: widget.width,
          points: [
            InkPoint(
              x: event.localPosition.dx,
              y: event.localPosition.dy,
              pressure: _pressureOf(event),
              t: 0,
            ),
          ],
        );
        setState(() {});
      },
      onPointerMove: (event) {
        final current = _current;
        if (current == null) return;
        final elapsed = DateTime.now().difference(_strokeStart ?? DateTime.now()).inMilliseconds;
        current.points.add(InkPoint(
          x: event.localPosition.dx,
          y: event.localPosition.dy,
          pressure: _pressureOf(event),
          t: elapsed,
        ));
        setState(() {});
      },
      onPointerUp: (event) {
        final stroke = _current;
        _current = null;
        if (stroke == null) return;
        _strokeStart = null;
        // 单点轻点也保留（屏幕上是个小圆点）
        if (stroke.points.isNotEmpty) {
          widget.onStrokeEnd(stroke);
        }
        setState(() {});
      },
      onPointerCancel: (event) {
        _current = null;
        _strokeStart = null;
        setState(() {});
      },
      child: CustomPaint(
        painter: InkPainter(current: _current),
        size: Size.infinite,
      ),
    );
  }
}

/// 进行中笔迹的绘制器（屏幕坐标）。
class InkPainter extends CustomPainter {
  const InkPainter({this.current});

  final InkStroke? current;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = current;
    if (stroke == null) return;
    final points = stroke.points;
    if (points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points.first.x, points.first.y),
        stroke.width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(points.first.x, points.first.y);
    for (final point in points.skip(1)) {
      path.lineTo(point.x, point.y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(InkPainter oldDelegate) => true;
}
