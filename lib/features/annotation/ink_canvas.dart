/// 手写标注层（设计文档 3.2 / 3.3）。
///
/// 用 `CustomPainter` 绘制笔迹，以**矢量形式**存储（点 + 压力 + 时间戳），
/// 而非截图（设计文档 3.3）。
///
/// ## 职责边界
///
/// 本组件只负责**捕获当前这一笔并在屏幕上实时跟手**（草稿，屏幕坐标）。
/// 已落定的笔迹由 `PageInkPainter` 在 pdfrx 的页面浮层里绘制
/// （页面坐标，见 `pdf_ink.dart`）—— 那里是正常的 widget 树，
/// `setState` 就能重绘，且随页面缩放/滚动自动对齐。
///
/// ## 输入设备
///
/// 支持 `mouse` / `trackpad` / `touch` / `stylus`。
/// 桌面端用鼠标或触控板即可书写；平板端用手写笔时压力值来自硬件。
///
/// @module ebook-studio/features/annotation/ink_canvas
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// 笔的类型。
///
/// 线宽的单位是 **PDF 页面点**（1/72 英寸），这样不同缩放下
/// 落到纸面上的粗细是一致的。
enum InkTool {
  /// 细笔，适合写字与勾画。
  pen('钢笔', 2, StrokeCap.round, 1),

  /// 粗一些，适合标注重点。
  marker('记号笔', 6, StrokeCap.round, 1),

  /// 荧光笔：宽、半透明、方头。绘制时用 multiply 混合，
  /// 让底下的文字透出来而不是被盖住。
  highlighter('荧光笔', 18, StrokeCap.square, 0.35);

  const InkTool(this.label, this.width, this.cap, this.opacity);

  final String label;

  /// 默认线宽（页面点）。
  final double width;

  /// 线端样式。荧光笔用方头，涂出来才像马克笔。
  final StrokeCap cap;

  /// 不透明度。荧光笔半透明。
  final double opacity;
}

/// 可选颜色（设计文档 3.5 的批注配色）。
const List<Color> kInkPalette = [
  Color(0xFFE53935), // 红
  Color(0xFF1E88E5), // 蓝
  Color(0xFF43A047), // 绿
  Color(0xFFFDD835), // 黄
  Color(0xFF8E24AA), // 紫
  Color(0xFF212121), // 黑
];

/// 一笔的矢量数据（与笔记边车的 strokes 结构一致，设计文档 1.5）。
///
/// 落盘时 `points` 由调用方转成**页面坐标**（见 `pdf_ink.dart`）。
class InkStroke {
  InkStroke({
    required this.color,
    required this.width,
    List<InkPoint>? points,
    this.cap = StrokeCap.round,
  }) : points = points ?? [];

  final Color color;

  /// 线宽（页面点）。
  final double width;

  final List<InkPoint> points;

  /// 线端样式。荧光笔是方头。
  final StrokeCap cap;

  /// 是否半透明（荧光笔）。
  bool get isTranslucent => color.a < 1;

  /// 序列化为边车 JSON（与 TS 侧 `InkStroke` 契约一致）。
  ///
  /// `cap` 不是契约里的字段，因此只在非默认值时以 `x-cap` 扩展键写出，
  /// 让 TS 侧读取时忽略它也不会出问题。
  Map<String, dynamic> toJson() => {
        'points': points.map((point) => point.toJson()).toList(),
        'color': '#${_hex(color)}',
        'width': width,
        if (cap != StrokeCap.round) 'x-cap': cap == StrokeCap.square ? 'square' : 'butt',
      };

  /// 从边车 JSON 还原。
  static InkStroke fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    final points = <InkPoint>[];
    if (rawPoints is List) {
      for (final item in rawPoints) {
        if (item is Map) points.add(InkPoint.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    return InkStroke(
      color: _parseColor(json['color']),
      width: (json['width'] as num?)?.toDouble() ?? 2,
      points: points,
      cap: switch (json['x-cap']) {
        'square' => StrokeCap.square,
        'butt' => StrokeCap.butt,
        _ => StrokeCap.round,
      },
    );
  }

  /// 带透明度信息的十六进制（`#AARRGGBB` 或 `#RRGGBB`）。
  static String _hex(Color color) {
    final argb = color.toARGB32();
    final alpha = (argb >> 24) & 0xFF;
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    if (alpha == 0xFF) return rgb;
    return '${alpha.toRadixString(16).padLeft(2, '0')}$rgb';
  }

  static Color _parseColor(Object? value) {
    if (value is! String) return const Color(0xFFE53935);
    final hex = value.replaceFirst('#', '');
    if (hex.length == 8) {
      final parsed = int.tryParse(hex, radix: 16);
      return parsed == null ? const Color(0xFFE53935) : Color(parsed);
    }
    if (hex.length == 6) {
      final parsed = int.tryParse(hex, radix: 16);
      return parsed == null ? const Color(0xFFE53935) : Color(0xFF000000 | parsed);
    }
    return const Color(0xFFE53935);
  }

  /// 值相等（颜色 / 线宽 / 线端 / 逐点相等）。
  ///
  /// 笔迹是值对象：测试断言、去重、撤销恢复都依赖按值比较；
  /// 「同一实例」的判断另有 [identical]。
  @override
  bool operator ==(Object other) =>
      other is InkStroke &&
      other.color == color &&
      other.width == width &&
      other.cap == cap &&
      _listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(color, width, cap, Object.hashAll(points));

  static bool _listEquals(List<InkPoint> a, List<InkPoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

  @override
  bool operator ==(Object other) =>
      other is InkPoint && other.x == x && other.y == y && other.pressure == pressure && other.t == t;

  @override
  int get hashCode => Object.hash(x, y, pressure, t);
}

/// 手写标注画布。
///
/// 只绘制**进行中的那一笔**（草稿）；已完成笔迹由页面浮层绘制。
/// 输出的笔迹 `points` 是**屏幕坐标**，`width` 是**页面点**，
/// 由调用方负责把点转成页面坐标后落盘。
class InkCanvas extends StatefulWidget {
  const InkCanvas({
    required this.onStrokeEnd,
    required this.color,
    required this.width,
    this.cap = StrokeCap.round,
    this.displayScale = 1,
    super.key,
  });

  /// 一笔结束时的回调。
  final void Function(InkStroke stroke) onStrokeEnd;

  final Color color;

  /// 线宽（页面点）。
  final double width;

  final StrokeCap cap;

  /// 页面 → 屏幕的缩放比。仅用于把草稿画成与最终一致的粗细。
  final double displayScale;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  InkStroke? _current;
  DateTime? _strokeStart;

  bool _isDrawingDevice(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse ||
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus ||
      kind == PointerDeviceKind.trackpad;

  /// 鼠标 / 触控板没有压感，统一给 1，避免笔迹被画得过细。
  double _pressureOf(PointerEvent event) {
    final pressure = event.pressure;
    if (pressure <= 0) return 1;
    return pressure.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 用 Listener 而非 GestureDetector：拿原始指针事件，不做手势竞争判定，
      // 落笔即画，延迟最低。平移冲突由外层的 AbsorbPointer 解决。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (!_isDrawingDevice(event.kind)) return;
        if (_current != null) return;
        _strokeStart = DateTime.now();
        _current = InkStroke(
          color: widget.color,
          width: widget.width,
          cap: widget.cap,
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
        _strokeStart = null;
        if (stroke != null && stroke.points.isNotEmpty) {
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
        painter: DraftInkPainter(stroke: _current, displayScale: widget.displayScale),
        size: Size.infinite,
      ),
    );
  }
}

/// 草稿笔迹绘制器（屏幕坐标）。
class DraftInkPainter extends CustomPainter {
  const DraftInkPainter({this.stroke, this.displayScale = 1});

  final InkStroke? stroke;

  /// 页面 → 屏幕缩放，用于把页面点线宽换算成屏幕线宽。
  final double displayScale;

  @override
  void paint(Canvas canvas, Size size) {
    final current = stroke;
    if (current == null) return;
    final points = current.points;
    if (points.isEmpty) return;

    final screenWidth = (current.width * displayScale).clamp(0.5, 200.0);
    final paint = Paint()
      ..color = current.color
      ..strokeWidth = screenWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = current.cap
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      // 半透明笔（荧光笔）用 multiply，让底下文字透出来
      ..blendMode = current.isTranslucent ? BlendMode.multiply : BlendMode.srcOver;

    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points.first.x, points.first.y),
        screenWidth / 2,
        Paint()
          ..color = current.color
          ..blendMode = paint.blendMode
          ..style = PaintingStyle.fill,
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
  bool shouldRepaint(DraftInkPainter oldDelegate) => true;
}
