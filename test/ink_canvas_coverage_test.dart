/// 阅读器手写层覆盖性测试（回归笔记本那类「局部画不了线」的命中问题）。
///
/// 背景：笔记本编辑器曾因 `Transform → OverflowBox(视口尺寸) →
/// SizedBox(页面尺寸)` 的命中测试边界，页面下部完全无法落笔
/// （OverflowBox 自身尺寸不含逆变换后的页面坐标）。
/// 阅读器的手写层是**盖在整个阅读区上的全区域 Listener**
/// （无 Transform / 超尺寸子组件），理论上没有同类问题 ——
/// 这里用确定的宿主尺寸验证：区域内任何位置的落笔都能收到。
library;

import 'package:ebook_studio/features/annotation/ink_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('InkCanvas 覆盖整个宿主区域：四角与中心的落笔都能收到', (tester) async {
    final strokes = <InkStroke>[];
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // 模拟阅读器：底层是 PDF 视图（这里用占位容器），上面盖手写层
              const Positioned.fill(child: ColoredBox(color: Colors.white)),
              Positioned.fill(
                child: InkCanvas(
                  color: const Color(0xFF212121),
                  width: 2,
                  onStrokeEnd: strokes.add,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // 四角（留 8px 边距避免打出窗口外）+ 中心，各自画一条短笔画
    final surface = const Size(800, 600);
    final probes = [
      const Offset(8, 8), // 左上
      Offset(surface.width - 8, 8), // 右上
      const Offset(8, 8) + Offset(0, surface.height - 16), // 左下
      Offset(surface.width - 8, surface.height - 8), // 右下
      surface.center(Offset.zero), // 中心
    ];

    var id = 0;
    for (final pos in probes) {
      final pointer = TestPointer(100 + id, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(pos, buttons: kPrimaryMouseButton));
      await tester.sendEventToBinding(pointer.move(pos + const Offset(12, 8), buttons: kPrimaryMouseButton));
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();
      id++;
    }

    expect(strokes, hasLength(probes.length),
        reason: '阅读区四角与中心的落笔都应被手写层收到（无命中死区）');
    for (final stroke in strokes) {
      expect(stroke.points, hasLength(2));
    }
  });


}
