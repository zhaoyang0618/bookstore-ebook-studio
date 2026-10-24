/// 笔记本数据层（GoodNotes / Notability 风格的手写笔记本）。
///
/// ## 文件格式
///
/// 一本笔记本一个 JSON 文件：`{目录}/{id}.notebook.json`。笔迹与
/// 阅读器批注共用同一套矢量结构（`InkStroke`：点 + 压力 + 时间戳），
/// 单位是**笔记页坐标**（页宽 1240 × 页高 1754，A4 @150dpi）。
///
/// 存进 MyLibrary 时目录为 `MyLibrary/notebooks/`（随图书馆同步）；
/// 未配置图书馆时用应用文档目录 `notebooks/`。
///
/// ## 会话
///
/// [NotebookSession] 是编辑器的纯逻辑层：笔画增删、擦除、撤销/重做、
/// 页面增删都走它，UI 只负责呈现。这样撤销/重做可以被单测覆盖。
///
/// @module ebook-studio/features/notebook/notebook_store
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../annotation/ink_canvas.dart';

/// 笔记页尺寸：A4 比例 @150dpi。
const Size kNotebookPageSize = Size(1240, 1754);

/// 纸张模板。
enum NotebookTemplate {
  blank('空白'),
  ruled('横线'),
  grid('方格'),
  dots('点阵');

  const NotebookTemplate(this.label);

  final String label;

  String get wire => name;

  static NotebookTemplate fromWire(String? value) =>
      NotebookTemplate.values.firstWhere(
        (t) => t.wire == value,
        orElse: () => NotebookTemplate.blank,
      );
}

/// 笔记本封面配色（GoodNotes 式的彩色封面）。
const List<Color> kNotebookCoverColors = [
  Color(0xFF2563EB), // 蓝
  Color(0xFFDC2626), // 红
  Color(0xFF16A34A), // 绿
  Color(0xFFD97706), // 橙
  Color(0xFF7C3AED), // 紫
  Color(0xFF0D9488), // 青
  Color(0xFFDB2777), // 粉
  Color(0xFF475569), // 灰
];

/// 笔记本里的一页。
class NotebookPage {
  const NotebookPage({
    required this.id,
    this.template = NotebookTemplate.ruled,
    this.strokes = const [],
    required this.updatedAt,
  });

  final String id;
  final NotebookTemplate template;

  /// 矢量笔迹（InkStroke JSON，笔记页坐标）。
  final List<Map<String, dynamic>> strokes;
  final String updatedAt;

  NotebookPage copyWith({
    NotebookTemplate? template,
    List<Map<String, dynamic>>? strokes,
    String? updatedAt,
  }) =>
      NotebookPage(
        id: id,
        template: template ?? this.template,
        strokes: strokes ?? this.strokes,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'template': template.wire,
        'strokes': strokes,
        'updated_at': updatedAt,
      };

  static NotebookPage fromJson(Map<String, dynamic> json) => NotebookPage(
        id: json['id'] as String? ?? _newId('pg'),
        template: NotebookTemplate.fromWire(json['template'] as String?),
        strokes: (json['strokes'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [],
        updatedAt: json['updated_at'] as String? ?? '',
      );
}

/// 一本笔记本（含全部页面）。
class Notebook {
  const Notebook({
    required this.id,
    required this.title,
    required this.coverColor,
    this.pageWidth = 1240,
    this.pageHeight = 1754,
    required this.pages,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;

  /// 封面颜色（ARGB int）。
  final int coverColor;
  final double pageWidth;
  final double pageHeight;
  final List<NotebookPage> pages;
  final String createdAt;
  final String updatedAt;

  Notebook copyWith({
    String? title,
    int? coverColor,
    List<NotebookPage>? pages,
    String? updatedAt,
  }) =>
      Notebook(
        id: id,
        title: title ?? this.title,
        coverColor: coverColor ?? this.coverColor,
        pageWidth: pageWidth,
        pageHeight: pageHeight,
        pages: pages ?? this.pages,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'schema_version': '1.0',
        'id': id,
        'title': title,
        'cover_color': coverColor,
        'page_width': pageWidth,
        'page_height': pageHeight,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'pages': pages.map((page) => page.toJson()).toList(),
      };

  static Notebook fromJson(Map<String, dynamic> json) {
    final now = DateTime.now().toUtc().toIso8601String();
    return Notebook(
      id: json['id'] as String? ?? _newId('nb'),
      title: json['title'] as String? ?? '未命名笔记本',
      coverColor: (json['cover_color'] as num?)?.toInt() ?? kNotebookCoverColors.first.toARGB32(),
      pageWidth: (json['page_width'] as num?)?.toDouble() ?? kNotebookPageSize.width,
      pageHeight: (json['page_height'] as num?)?.toDouble() ?? kNotebookPageSize.height,
      pages: (json['pages'] as List?)?.whereType<Map<String, dynamic>>().map(NotebookPage.fromJson).toList() ?? const [],
      createdAt: json['created_at'] as String? ?? now,
      updatedAt: json['updated_at'] as String? ?? now,
    );
  }
}

String _newId(String prefix) =>
    '$prefix-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(0x10000).toRadixString(36)}';

/// 笔记本的本地存储：一个笔记本一个 JSON 文件。
class NotebookStore {
  NotebookStore(this.dir);

  /// 笔记本目录（`MyLibrary/notebooks/` 或应用文档 `notebooks/`）。
  final String dir;

  static const String fileSuffix = '.notebook.json';

  final JsonEncoder _encoder = const JsonEncoder.withIndent('  ');

  /// 全部笔记本，按更新时间降序。
  List<Notebook> list() {
    final directory = Directory(dir);
    if (!directory.existsSync()) return const [];
    final notebooks = <Notebook>[];
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith(fileSuffix)) continue;
      try {
        final json = jsonDecode(entity.readAsStringSync());
        if (json is! Map<String, dynamic>) continue;
        notebooks.add(Notebook.fromJson(json));
      } on FormatException {
        // 单个坏文件不拖垮列表
        continue;
      }
    }
    notebooks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notebooks;
  }

  Notebook? read(String id) {
    final file = File(_pathOf(id));
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync());
    if (json is! Map<String, dynamic>) return null;
    return Notebook.fromJson(json);
  }

  /// 新建一本笔记本：标题、封面色、首页纸张模板。
  Notebook create({
    required String title,
    required int coverColor,
    NotebookTemplate template = NotebookTemplate.ruled,
    String? now,
  }) {
    final created = now ?? DateTime.now().toUtc().toIso8601String();
    final notebook = Notebook(
      id: _newId('nb'),
      title: title.trim().isEmpty ? '未命名笔记本' : title.trim(),
      coverColor: coverColor,
      pageWidth: kNotebookPageSize.width,
      pageHeight: kNotebookPageSize.height,
      pages: [NotebookPage(id: _newId('pg'), template: template, updatedAt: created)],
      createdAt: created,
      updatedAt: created,
    );
    save(notebook);
    return notebook;
  }

  /// 原子保存：先写临时文件再改名，中途断电也不会留下半个文件。
  void save(Notebook notebook) {
    Directory(dir).createSync(recursive: true);
    final target = _pathOf(notebook.id);
    final tmp = File('$target.tmp');
    tmp.writeAsStringSync('${_encoder.convert(notebook.toJson())}\n');
    tmp.renameSync(target);
  }

  void delete(String id) {
    final file = File(_pathOf(id));
    if (file.existsSync()) file.deleteSync();
  }

  String _pathOf(String id) => p.join(dir, '$id$fileSuffix');
}

// ---------- 编辑会话（纯逻辑，可单测） ----------

/// 一次可撤销的操作。
class NotebookOp {
  NotebookOp.addStroke(this.pageIndex, this.added) : removed = const [];

  NotebookOp.removeStrokes(this.pageIndex, this.removed) : added = const [];

  final int pageIndex;

  /// 新增的笔画（撤销时按身份移除）。
  final List<InkStroke> added;

  /// 删除的笔画及其在页面中的下标（撤销时按原位插回）。
  final List<({int index, InkStroke stroke})> removed;
}

/// 一本笔记本的编辑会话。
///
/// 持有笔记本数据与undo/redo 栈；UI 监听 [notifyListeners] 重绘。
/// 结构性操作（加页 / 删页 / 换模板）不可撤销，会清空两栈 —— 与
/// GoodNotes 行为一致。
class NotebookSession extends ChangeNotifier {
  NotebookSession(this.notebook) : _pageStrokes = _fromNotebook(notebook);

  Notebook notebook;

  final Map<int, List<InkStroke>> _pageStrokes;

  final List<NotebookOp> _undoStack = [];
  final List<NotebookOp> _redoStack = [];

  /// 是否有未保存的修改。
  bool dirty = false;

  static Map<int, List<InkStroke>> _fromNotebook(Notebook notebook) {
    final map = <int, List<InkStroke>>{};
    for (var i = 0; i < notebook.pages.length; i++) {
      map[i] = notebook.pages[i].strokes.map(InkStroke.fromJson).toList();
    }
    return map;
  }

  /// 当前页下标（0 起始）。
  int currentPage = 0;

  int get pageCount => notebook.pages.length;

  /// 是否能撤销 / 重做（任意页）。
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 某页的笔画（只读快照）。
  List<InkStroke> strokesOf(int pageIndex) =>
      List.unmodifiable(_pageStrokes[pageIndex] ?? const []);

  /// 追加一笔。
  void addStroke(int pageIndex, InkStroke stroke) {
    _strokesAt(pageIndex).add(stroke);
    _undoStack.add(NotebookOp.addStroke(pageIndex, [stroke]));
    _redoStack.clear();
    _markDirty();
  }

  /// 擦除：删除所有与 [point] 距离小于 [radius] 的笔画。
  ///
  /// 一次拖动会产生大量 move 事件，[mergeWithLast] 为真时把本次命中
  /// 合并进上一条擦除记录 —— 整段拖动只算一次撤销。
  /// 返回擦掉的笔数。
  int eraseAt(int pageIndex, Offset point, double radius, {bool mergeWithLast = false}) {
    final strokes = _strokesAt(pageIndex);
    final hit = <({int index, InkStroke stroke})>[];
    for (var i = strokes.length - 1; i >= 0; i--) {
      if (strokeContainsPoint(strokes[i], point, radius)) {
        hit.add((index: i, stroke: strokes[i]));
      }
    }
    if (hit.isEmpty) return 0;
    for (final entry in hit) {
      strokes.removeAt(entry.index);
    }
    final last = mergeWithLast ? _undoStack.lastOrNull : null;
    if (last != null && last.removed.isNotEmpty && last.pageIndex == pageIndex) {
      // 合并进上一条擦除记录：本次下标是「已删掉一批之后」的列表里的，
      // 换算回本操作开始前的原始下标，撤销时才能按原顺序插回
      for (final entry in hit) {
        last.removed.add((index: _originalIndexOf(entry.index, last.removed), stroke: entry.stroke));
      }
    } else {
      _undoStack.add(NotebookOp.removeStrokes(pageIndex, hit));
      _redoStack.clear();
    }
    _markDirty();
    return hit.length;
  }

  /// 把「已删除若干笔后的下标」换算成删除前的原始下标。
  ///
  /// 例：原列表 [a, b, c]，先删 a（原始 0）→ 现列表 [b, c]，
  /// b 的现下标 0 → 原始下标 1。
  int _originalIndexOf(int currentIndex, List<({int index, InkStroke stroke})> alreadyRemoved) {
    var original = currentIndex;
    final removedIndices = alreadyRemoved.map((entry) => entry.index).toList()..sort();
    for (final removed in removedIndices) {
      if (removed <= original) {
        original++;
      } else {
        break;
      }
    }
    return original;
  }

  /// 清空一页。
  void clearPage(int pageIndex) {
    final strokes = _strokesAt(pageIndex);
    if (strokes.isEmpty) return;
    final removed = <({int index, InkStroke stroke})>[
      for (var i = strokes.length - 1; i >= 0; i--) (index: i, stroke: strokes[i]),
    ];
    strokes.clear();
    _undoStack.add(NotebookOp.removeStrokes(pageIndex, removed));
    _redoStack.clear();
    _markDirty();
  }

  void undo() {
    final op = _undoStack.removeLast();
    final strokes = _strokesAt(op.pageIndex);
    for (final stroke in op.added) {
      strokes.removeWhere((existing) => identical(existing, stroke));
    }
    // 原位插回：按下标从大到小排（removeStrokes 记录的顺序即倒序）
    final restored = [...op.removed]..sort((a, b) => a.index.compareTo(b.index));
    for (final entry in restored) {
      strokes.insert(entry.index.clamp(0, strokes.length), entry.stroke);
    }
    _redoStack.add(op);
    _markDirty();
  }

  void redo() {
    final op = _redoStack.removeLast();
    final strokes = _strokesAt(op.pageIndex);
    strokes.addAll(op.added);
    for (final entry in op.removed) {
      // 撤销把同实例原位插回过，按身份找到再删，不依赖下标
      final index = strokes.indexWhere((existing) => identical(existing, entry.stroke));
      if (index >= 0) strokes.removeAt(index);
    }
    _undoStack.add(op);
    _markDirty();
  }

  /// 把会话状态写回 [NotebookPage]（保存前调用）。
  Notebook snapshot() {
    final now = DateTime.now().toUtc().toIso8601String();
    final pages = <NotebookPage>[];
    for (var i = 0; i < notebook.pages.length; i++) {
      final page = notebook.pages[i];
      final strokes = _pageStrokes[i] ?? const <InkStroke>[];
      pages.add(page.copyWith(
        strokes: strokes.map((stroke) => stroke.toJson()).toList(),
        updatedAt: now,
      ));
    }
    notebook = notebook.copyWith(pages: pages, updatedAt: now);
    return notebook;
  }

  // ---------- 页面结构 ----------

  /// 在当前页之后插入一页。
  void insertPageAfterCurrent(NotebookTemplate template) {
    final now = DateTime.now().toUtc().toIso8601String();
    notebook = notebook.copyWith(
      pages: [
        ...notebook.pages.take(currentPage + 1),
        NotebookPage(id: _newId('pg'), template: template, updatedAt: now),
        ...notebook.pages.skip(currentPage + 1),
      ],
      updatedAt: now,
    );
    currentPage = currentPage + 1;
    _clearHistoryAndMarkDirty();
  }

  /// 删除一页（至少保留一页）。
  void deletePage(int pageIndex) {
    if (notebook.pages.length <= 1) return;
    notebook = notebook.copyWith(
      pages: [...notebook.pages]..removeAt(pageIndex),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    if (currentPage >= notebook.pages.length) currentPage = notebook.pages.length - 1;
    _clearHistoryAndMarkDirty();
  }

  void setPageTemplate(int pageIndex, NotebookTemplate template) {
    final page = notebook.pages[pageIndex];
    notebook = notebook.copyWith(
      pages: [...notebook.pages]..[pageIndex] = page.copyWith(template: template),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    _clearHistoryAndMarkDirty();
  }

  // ---------- 内部 ----------

  List<InkStroke> _strokesAt(int pageIndex) =>
      _pageStrokes.putIfAbsent(pageIndex, () => <InkStroke>[]);

  void _clearHistoryAndMarkDirty() {
    _undoStack.clear();
    _redoStack.clear();
    _markDirty();
  }

  void _markDirty() {
    dirty = true;
    notifyListeners();
  }
}

/// 一笔是否穿过以 [point] 为圆心、[radius] 为半径的圆。
///
/// 擦除的命中判定：逐段做点到线段距离检测；单点笔画按圆心距算。
/// 笔画本身有粗细，命中范围是 `radius + 半线宽`。
bool strokeContainsPoint(InkStroke stroke, Offset point, double radius) {
  if (stroke.points.isEmpty) return false;
  final threshold = radius + stroke.width / 2;
  bool near(Offset a) => (a - point).distance <= threshold;

  final first = Offset(stroke.points.first.x, stroke.points.first.y);
  if (stroke.points.length == 1) return near(first);

  for (var i = 0; i < stroke.points.length - 1; i++) {
    final a = Offset(stroke.points[i].x, stroke.points[i].y);
    final b = Offset(stroke.points[i + 1].x, stroke.points[i + 1].y);
    if (_distanceToSegment(point, a, b) <= threshold) return true;
  }
  return false;
}

/// 点到线段的距离。
double _distanceToSegment(Offset point, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.distanceSquared;
  if (lengthSquared == 0) return (point - a).distance;
  final ap = point - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared).clamp(0.0, 1.0).toDouble();
  final projection = a + ab * t;
  return (point - projection).distance;
}
