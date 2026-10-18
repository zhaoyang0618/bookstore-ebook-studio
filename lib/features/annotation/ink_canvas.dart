/// 手写标注层（设计文档 3.2 / 3.3）。
///
/// 用 `CustomPainter` 绘制笔迹，以**矢量形式**存储（点 + 压力 + 时间戳），
/// 而非截图（设计文档 3.3）。
///
/// 平板端手势（设计文档 3.5）：单指标注，双指翻页，手掌拒绝自动启用。
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// 一笔的矢量数据（与笔记边车的 strokes 结构一致，设计文档 1.5）。
class InkStroke {
  InkStroke({required this.color, required this.width, List<InkPoint>? points}) : points = points ?? [];

  final Color color;
  final double width;
  final List<InkPoint> points;

  /// 序列化为边车 JSON 里的形状。
  Map<String, dynamic> toJson() => {
        'points': points.map((point) => point.toJson()).toList(),
        'color': '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
        'width': width,
      };
}

/// 笔迹中的一个点。
class InkPoint {
  InkPoint({required this.x, required this.y, this.pressure = 1, this.t = 0});

  final double x;
  final double y;

  /// 压感（0 ~ 1），来自触控 / 手写笔。
  final double pressure;

  /// 相对笔迹起点的毫秒数。
  final int t;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'pressure': pressure, 't': t};
}

/// 手写标注画布。
class InkCanvas extends StatefulWidget {
  const InkCanvas({required this.onStrokeEnd, this.color = const Color(0xFFFF0000), this.width = 2, super.key});

  /// 一笔结束时的回调（返回矢量笔迹）。
  final void Function(InkStroke stroke) onStrokeEnd;
  final Color color;
  final double width;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  final List<InkStroke> _strokes = [];
  InkStroke? _current;
  DateTime? _strokeStart;

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Listener 只处理单指：多指事件直接忽略，把翻页手势留给父级
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.touch && event.kind != PointerDeviceKind.stylus) return;
        if (_current != null) return;
        _strokeStart = DateTime.now();
        _current = InkStroke(
          color: widget.color,
          width: widget.width,
          points: [InkPoint(x: event.localPosition.dx, y: event.localPosition.dy, t: 0)],
        );
      },
      onPointerMove: (event) {
        if (_current == null) return;
        final elapsed = DateTime.now().difference(_strokeStart ?? DateTime.now()).inMilliseconds;
        _current!.points.add(InkPoint(
          x: event.localPosition.dx,
          y: event.localPosition.dy,
          pressure: event.pressure,
          t: elapsed,
        ));
        setState(() {});
      },
      onPointerUp: (event) {
        final stroke = _current;
        _current = null;
        if (stroke == null) return;
        // 单点轻点也保留一个小圆点
        if (stroke.points.isNotEmpty) {
          _strokes.add(stroke);
          widget.onStrokeEnd(stroke);
        }
        setState(() {});
      },
      onPointerCancel: (event) {
        _current = null;
        setState(() {});
      },
      child: CustomPaint(
        painter: InkPainter(strokes: _strokes, current: _current),
        size: Size.infinite,
      ),
    );
  }
}

/// 笔迹绘制器。
class InkPainter extends CustomPainter {
  const InkPainter({required this.strokes, this.current});

  final List<InkStroke> strokes;
  final InkStroke? current;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in [...strokes, if (current != null) current!]) {
      final points = stroke.points;
      if (points.isEmpty) continue;
      if (points.length == 1) {
        // 单点画一个小圆点，保证轻点也有痕迹
        final point = points.first;
        canvas.drawCircle(Offset(point.x, point.y), stroke.width / 2, Paint()..color = stroke.color);
        continue;
      }
      final path = Path()..moveTo(points.first.x, points.first.y);
      for (final point in points.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke.color
          ..strokeWidth = stroke.width
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(InkPainter oldDelegate) => true;
}
