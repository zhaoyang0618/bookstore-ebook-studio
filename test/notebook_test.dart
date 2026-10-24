/// 笔记本功能测试：文件格式、会话（增删擦/撤销重做/页面结构）、擦除命中。
library;

import 'dart:io';

import 'package:ebook_studio/features/annotation/ink_canvas.dart';
import 'package:ebook_studio/features/notebook/notebook_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一条简单的水平线（页面坐标，方便橡皮命中测试）。
InkStroke hLine(double x0, double y, double x1, {Color color = const Color(0xFF212121), double width = 2}) {
  return InkStroke(
    color: color,
    width: width,
    points: [
      InkPoint(x: x0, y: y),
      InkPoint(x: (x0 + x1) / 2, y: y),
      InkPoint(x: x1, y: y),
    ],
  );
}

void main() {
  late Directory temp;
  late NotebookStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('notebook-test');
    store = NotebookStore(temp.path);
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('NotebookStore：文件读写', () {
    test('create 建文件、首页用指定模板', () {
      final notebook = store.create(title: '读书笔记', coverColor: 0xFF2563EB, template: NotebookTemplate.grid);
      expect(notebook.title, '读书笔记');
      expect(notebook.coverColor, 0xFF2563EB);
      expect(notebook.pages, hasLength(1));
      expect(notebook.pages.first.template, NotebookTemplate.grid);
      expect(File('${temp.path}/${notebook.id}.notebook.json').existsSync(), isTrue);
      expect(store.list().map((n) => n.id), contains(notebook.id));
    });

    test('空标题落到「未命名笔记本」', () {
      final notebook = store.create(title: '   ', coverColor: 0);
      expect(notebook.title, '未命名笔记本');
    });

    test('save + read 往返：笔迹逐字段一致', () {
      final notebook = store.create(title: '往返', coverColor: 0xFF16A34A);
      final session = NotebookSession(notebook);
      session.addStroke(0, hLine(10, 20, 300, color: const Color(0xFFE53935), width: 3.5));
      session.addStroke(0, hLine(0, 40, 500, color: const Color(0x881E88E5), width: 16));

      store.save(session.snapshot());
      final restored = store.read(notebook.id)!;
      expect(restored.pages.first.strokes, hasLength(2));

      final first = InkStroke.fromJson(restored.pages.first.strokes[0]);
      expect(first.color, const Color(0xFFE53935));
      expect(first.width, 3.5);
      expect(first.points.map((p) => (p.x, p.y)).toList(), [
        (10.0, 20.0),
        (155.0, 20.0),
        (300.0, 20.0),
      ]);
    });

    test('list 按更新时间降序', () {
      store.create(title: '早', coverColor: 0, now: '2026-10-01T00:00:00Z');
      store.create(title: '晚', coverColor: 0, now: '2026-10-20T00:00:00Z');
      final titles = store.list().map((n) => n.title).toList();
      expect(titles, ['晚', '早']);
    });

    test('delete 删文件；read 不存在的 id 返回 null', () {
      final notebook = store.create(title: '待删', coverColor: 0);
      store.delete(notebook.id);
      expect(store.read(notebook.id), isNull);
      expect(store.list(), isEmpty);
    });

    test('损坏的文件被跳过，不拖垮列表', () {
      store.create(title: '好的', coverColor: 0);
      File('${temp.path}/bad.notebook.json').writeAsStringSync('{ not json');
      expect(store.list(), hasLength(1));
    });

    test('原子保存不残留 .tmp', () {
      final notebook = store.create(title: '原子', coverColor: 0);
      store.save(notebook.copyWith(title: '原子 2'));
      expect(Directory(temp.path).listSync().whereType<File>().map((f) => f.path.endsWith('.tmp')), everyElement(isFalse));
    });
  });

  group('NotebookSession：笔画与撤销/重做', () {
    test('addStroke 后笔画可见', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      session.addStroke(0, hLine(0, 0, 10));
      expect(session.strokesOf(0), hasLength(1));
      expect(session.dirty, isTrue);
    });

    test('undo / redo：加一笔撤销后消失，重做后回来', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      final a = hLine(0, 10, 100);
      final b = hLine(0, 20, 100);
      session.addStroke(0, a);
      session.addStroke(0, b);
      expect(session.strokesOf(0), hasLength(2));

      session.undo();
      expect(session.strokesOf(0), [a]);

      session.undo();
      expect(session.strokesOf(0), isEmpty);
      expect(session.canUndo, isFalse);

      session.redo();
      expect(session.strokesOf(0), [a]);
      session.redo();
      expect(session.strokesOf(0), [a, b]);
      expect(session.canRedo, isFalse);
    });

    test('新笔画会清空重做栈', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      session.addStroke(0, hLine(0, 0, 10));
      session.undo();
      expect(session.canRedo, isTrue);
      session.addStroke(0, hLine(0, 30, 40));
      expect(session.canRedo, isFalse);
    });

    test('擦除可以撤销：笔画按原位恢复', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      final a = hLine(0, 10, 100);
      final b = hLine(0, 50, 100);
      final c = hLine(0, 90, 100);
      session.addStroke(0, a);
      session.addStroke(0, b);
      session.addStroke(0, c);

      expect(session.eraseAt(0, const Offset(50, 50), 10), 1);
      expect(session.strokesOf(0), [a, c]);

      session.undo();
      expect(session.strokesOf(0), [a, b, c]);
    });

    test('连续擦除拖动合并为一次撤销', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      final a = hLine(0, 10, 100);
      final b = hLine(0, 50, 100);
      session.addStroke(0, a);
      session.addStroke(0, b);

      session.eraseAt(0, const Offset(50, 10), 5);
      // 拖动经过第二笔：mergeWithLast = true
      session.eraseAt(0, const Offset(50, 50), 5, mergeWithLast: true);
      expect(session.strokesOf(0), isEmpty);

      session.undo();
      expect(session.strokesOf(0), [a, b]);
    });

    test('clearPage 一次性撤销整页', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      final a = hLine(0, 10, 100);
      final b = hLine(0, 50, 100);
      session.addStroke(0, a);
      session.addStroke(0, b);
      session.clearPage(0);
      expect(session.strokesOf(0), isEmpty);

      session.undo();
      expect(session.strokesOf(0), [a, b]);
    });

    test('snapshot 把会话笔画写回 notebook', () {
      final notebook = store.create(title: 's', coverColor: 0);
      final session = NotebookSession(notebook);
      session.addStroke(0, hLine(0, 10, 100));
      final snapshot = session.snapshot();
      expect(identical(snapshot, session.notebook), isTrue);
      expect(snapshot.pages.first.strokes, hasLength(1));
      expect(snapshot.updatedAt, isNot(notebook.updatedAt));
    });
  });

  group('NotebookSession：页面结构', () {
    test('insertPageAfterCurrent 插到当前页后并切换过去', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      session.insertPageAfterCurrent(NotebookTemplate.grid);
      expect(session.pageCount, 2);
      expect(session.currentPage, 1);
      expect(session.notebook.pages[1].template, NotebookTemplate.grid);
      // 结构操作清空撤销栈
      expect(session.canUndo, isFalse);
    });

    test('deletePage 删指定页，当前页自动回退', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      session.insertPageAfterCurrent(NotebookTemplate.blank);
      session.insertPageAfterCurrent(NotebookTemplate.grid);
      expect(session.pageCount, 3);
      session.deletePage(2);
      expect(session.pageCount, 2);
      expect(session.currentPage, 1);
    });

    test('最后一页不能删', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      session.deletePage(0);
      expect(session.pageCount, 1);
    });

    test('setPageTemplate 改指定页模板', () {
      final session = NotebookSession(store.create(title: 's', coverColor: 0));
      session.setPageTemplate(0, NotebookTemplate.dots);
      expect(session.notebook.pages.first.template, NotebookTemplate.dots);
    });
  });

  group('橡皮命中：strokeContainsPoint', () {
    test('点在线段上命中，远离不命中', () {
      final stroke = hLine(0, 100, 200);
      expect(strokeContainsPoint(stroke, const Offset(50, 100), 6), isTrue);
      // 端点延伸线外但在圆内也算命中（半径覆盖）
      expect(strokeContainsPoint(stroke, const Offset(203, 100), 6), isTrue);
      expect(strokeContainsPoint(stroke, const Offset(50, 130), 6), isFalse);
    });

    test('粗笔画按自身宽度扩大命中范围', () {
      final stroke = hLine(0, 100, 200, width: 16);
      expect(strokeContainsPoint(stroke, const Offset(50, 112), 6), isTrue);
    });

    test('单点笔画按圆心距判定', () {
      final stroke = InkStroke(
        color: const Color(0xFF212121),
        width: 2,
        points: [InkPoint(x: 100, y: 100)],
      );
      expect(strokeContainsPoint(stroke, const Offset(103, 101), 6), isTrue);
      expect(strokeContainsPoint(stroke, const Offset(120, 100), 6), isFalse);
    });

    test('空笔画不命中', () {
      final stroke = InkStroke(color: const Color(0xFF212121), width: 2);
      expect(strokeContainsPoint(stroke, Offset.zero, 50), isFalse);
    });
  });

  group('模板与常量', () {
    test('模板 wire 值往返', () {
      for (final template in NotebookTemplate.values) {
        expect(NotebookTemplate.fromWire(template.wire), template);
      }
      expect(NotebookTemplate.fromWire('unknown'), NotebookTemplate.blank);
      expect(NotebookTemplate.fromWire(null), NotebookTemplate.blank);
    });

    test('页面尺寸是 A4 比例', () {
      expect(kNotebookPageSize.width / kNotebookPageSize.height, closeTo(297 / 420, 0.01));
    });
  });
}
