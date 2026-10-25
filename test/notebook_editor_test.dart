/// 笔记编辑器的 widget 测试：初始铺满缩放、指针过滤。
///
/// 背景：v0.9.6 用户日志显示初始 cover 缩放**没有生效**（transform 停在
/// identity，scale=1.0），页面 1240 宽塞在 800 宽视口里。这里用确定的
/// 视口尺寸本地复现，把「加了 postFrame 却没生效」的问题钉死。
library;

import 'dart:io';

import 'package:ebook_studio/features/notebook/notebook_editor.dart';
import 'package:ebook_studio/features/notebook/notebook_store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late NotebookStore store;
  late Notebook notebook;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('notebook-editor-test');
    store = NotebookStore(temp.path);
    notebook = store.create(title: '测试', coverColor: 0xFF2563EB, template: NotebookTemplate.ruled);
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpEditor(WidgetTester tester, {Size size = const Size(800, 444)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: NotebookEditorPage(
            notebook: notebook,
            store: store,
            onSaved: (_) {},
          ),
        ),
      ),
    );
    // 触发 LayoutBuilder + postFrame 初始缩放
    await tester.pump();
    await tester.pump();
  }

  Matrix4 transformOf(WidgetTester tester) {
    final dynamic state = tester.state(find.byType(NotebookEditorPage));
    return state.debugTransform as Matrix4;
  }

  testWidgets('初始缩放 = 铺满视口（cover scale），不是 identity', (tester) async {
    await pumpEditor(tester);

    final transform = transformOf(tester);
    final scale = transform.getMaxScaleOnAxis();
    final cover = 800 / kNotebookPageSize.width; // 0.645...
    expect(scale, closeTo(cover, 0.001),
        reason: '视口 800x444 时 cover = ${cover.toStringAsFixed(3)}，'
            '实际 $scale —— 初始铺满没有生效（v0.9.6 用户日志复现的问题）');
  });

  testWidgets('窗口缩放后：不重置用户缩放，但纸仍覆盖视口', (tester) async {
    await pumpEditor(tester);
    final scaleBefore = transformOf(tester).getMaxScaleOnAxis();

    await tester.binding.setSurfaceSize(const Size(400, 900));
    await tester.pump();
    await tester.pump();

    // 缩放保持用户当前的值（不强行重置），但边界钳制保证纸覆盖新视口
    expect(transformOf(tester).getMaxScaleOnAxis(), scaleBefore);
    final origin = MatrixUtils.transformPoint(transformOf(tester), Offset.zero);
    expect(origin.dx, lessThanOrEqualTo(0.0));
    expect(origin.dx + kNotebookPageSize.width * scaleBefore, greaterThanOrEqualTo(400.0));
    expect(origin.dy, lessThanOrEqualTo(0.0));
    expect(origin.dy + kNotebookPageSize.height * scaleBefore, greaterThanOrEqualTo(900.0));
  });

  testWidgets('有按键的 mouse 拖动画线（回归：真实点击仍可画）', (tester) async {
    await pumpEditor(tester);
    final center = tester.getCenter(find.byType(NotebookEditorPage));

    // 探查命中测试：这个点上到底命中了什么
    final rootBox = tester.renderObject<RenderBox>(find.byType(NotebookEditorPage));
    final hitResult = BoxHitTestResult();
    final didHit = rootBox.hitTest(hitResult, position: rootBox.globalToLocal(center));
    final hitTypes = hitResult.path
        .map((entry) => entry.target.runtimeType.toString())
        .toList();
    // ignore: avoid_print
    print('HITTEST center=$center didHit=$didHit targets=${hitTypes.take(12)}');
    final pageRect = tester.getRect(find.byType(Scaffold));
    // ignore: avoid_print
    print('HITTEST scaffold-rect=$pageRect');

    final down = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(down.down(center, buttons: kPrimaryMouseButton));
    await tester.sendEventToBinding(down.move(center + const Offset(80, 60), buttons: kPrimaryMouseButton));
    await tester.sendEventToBinding(down.up());
    await tester.pump(const Duration(seconds: 1)); // 自动保存防抖落盘

    expect(store.read(notebook.id)!.pages.first.strokes, isNotEmpty,
        reason: '真实点击拖动应当画线');
  });
}
