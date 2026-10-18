/// 把墨迹写成 PDF **原生 `/Ink` 注释**（设计文档 3.3 / 4.2）。
///
/// ## 为什么必须是原生注释
///
/// 设计文档 4.2 的核心验收标准是：
/// **iPad 上手写 PDF 批注，Mac 上 dsh 版打开 PDF 可见墨迹**。
/// 这要求墨迹以 PDF 标准注释对象存在于文件里，而不是应用私有的边车数据 ——
/// 这样 PDF.js、Acrobat、Preview、PDFium 都能直接渲染。
///
/// ## 写入的对象长什么样
///
/// ```pdf
/// 2000 0 obj
/// << /Type /Annot /Subtype /Ink
///    /Rect [x0 y0 x1 y1]
///    /InkList [[x1 y1 x2 y2 ...]]      % 每条笔迹一个点序列
///    /C [r g b]                         % 颜色
///    /Border [0 0 2]                    % 线宽
///    /F 4                               % Print
///    /T (ebook studio)                  % 作者
///    /NM (ink-1792321021394)            % 唯一名，避免重复导入
///    /M (D:20261018190000Z)             % 修改时间
///    /P 3 0 R                           % 所属页面
/// >>
/// endobj
/// ```
///
/// ## 坐标系
///
/// 墨迹存的是**阅读器页面坐标**（y 向下、原点左上），
/// 而 PDF 注释用**PDF 坐标**（y 向上、原点左下），
/// 因此写入时要用 `pageHeight - y` 翻转 —— 与 TS 侧
/// `readerToPdfPoint()` 的做法一致。
///
/// @module ebook-studio/pdf/pdf_ink_export
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../features/annotation/ink_canvas.dart';
import 'pdf_reader.dart';
import 'pdf_syntax.dart';

/// 写回 PDF 前的备份目录（应用启动时设置）。
///
/// 原地覆盖用户的书是有风险的操作，因此写入前先备份一份，
/// 出问题能人工回滚。
String? pdfBackupDir;

/// 导出结果。
class InkExportResult {
  const InkExportResult({
    required this.outputPath,
    required this.pageNumber,
    required this.annotationCount,
    required this.strokeCount,
    required this.bytes,
    this.backupPath,
  });

  final String outputPath;

  /// 写入的页码（1 起始）。
  final int pageNumber;

  /// 本次新增的注释对象数。
  final int annotationCount;

  /// 本次新增的笔迹条数。
  final int strokeCount;

  /// 输出文件大小。
  final int bytes;

  /// 原文件的备份路径（原地覆盖时提供，便于回滚）。
  final String? backupPath;
}

/// 把某页的墨迹导出成原生 `/Ink` 注释，写到 [outputPath]。
///
/// - [pageNumber]：1 起始的页码
/// - [strokesByAnnotation]：一份批注对应一组笔迹（一条批注可含多笔）
/// - 采用**增量更新**：不重写原文件内容，只在尾部追加
///
/// 返回写入统计；失败抛 [PdfInkExportException]。
InkExportResult exportInkAnnotations({
  required String sourcePath,
  required String outputPath,
  required int pageNumber,
  required List<InkAnnotationInput> annotations,
  String author = 'ebook studio',
  DateTime? now,
}) {
  if (annotations.isEmpty) {
    throw PdfInkExportException('没有要导出的墨迹');
  }

  final data = File(sourcePath).readAsBytesSync();
  final reader = PdfFileReader.fromBytes(data);
  final startXref = findLastStartXref(data);

  final pages = reader.collectPages();
  if (pageNumber < 1 || pageNumber > pages.length) {
    throw PdfInkExportException('页码 $pageNumber 超出范围（共 ${pages.length} 页）');
  }
  final pageRef = pages[pageNumber - 1];
  final pageDict = reader.resolve(pageRef);
  if (pageDict is! PdfDict) {
    throw PdfInkExportException('第 $pageNumber 页的对象无法解析');
  }

  final geometry = reader.pageGeometry(pageDict);
  final mediaBox = geometry.mediaBox;
  final pageHeight = mediaBox[3] - mediaBox[1];
  final pageWidth = mediaBox[2] - mediaBox[0];
  if (pageHeight <= 0 || pageWidth <= 0) {
    throw PdfInkExportException('页面的 MediaBox 不合法：$mediaBox');
  }

  // 目前只支持不旋转的页面。旋转页面需要额外的坐标变换，
  // 宁可明确报错，也不要写进去位置错误的注释。
  if (geometry.rotate % 360 != 0) {
    throw PdfInkExportException(
      '第 $pageNumber 页带 /Rotate ${geometry.rotate}，暂不支持导出（避免写入位置错误的注释）',
    );
  }

  final writer = PdfIncrementalWriter(reader);
  final timestamp = (now ?? DateTime.now().toUtc());
  final pdfDate = _pdfDate(timestamp);

  final newRefs = <PdfRef>[];
  var strokeCount = 0;

  for (final annotation in annotations) {
    if (annotation.strokes.isEmpty) continue;
    final inkList = <PdfObject>[];
    final bounds = _Bounds();

    for (final stroke in annotation.strokes) {
      if (stroke.points.isEmpty) continue;
      final numbers = <PdfObject>[];
      for (final point in stroke.points) {
        // 阅读器坐标（y 向下）→ PDF 坐标（y 向上）
        final x = point.x + mediaBox[0];
        final y = pageHeight - point.y + mediaBox[1];
        numbers.add(PdfNumber(_round(x)));
        numbers.add(PdfNumber(_round(y)));
        bounds.include(x, y);
      }
      inkList.add(PdfArray(numbers));
      strokeCount += 1;
    }
    if (inkList.isEmpty) continue;

    // 线宽取该批注第一条笔迹的宽度（PDF 注释只有统一的边框宽度）
    final width = annotation.strokes.first.width;
    final color = _colorComponents(annotation.color);
    // /Rect 需要把线宽与线端一并算进去，否则粗线会被裁掉
    bounds.expand(width / 2 + 1);

    final annotNumber = writer.allocate();
    final annotDict = PdfDict({
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Ink'),
      'Rect': PdfArray([
        PdfNumber(_round(bounds.left)),
        PdfNumber(_round(bounds.bottom)),
        PdfNumber(_round(bounds.right)),
        PdfNumber(_round(bounds.top)),
      ]),
      'InkList': PdfArray(inkList),
      'C': PdfArray(color.map((c) => PdfNumber(c)).toList()),
      'Border': PdfArray([const PdfNumber(0), const PdfNumber(0), PdfNumber(_round(width))]),
      'F': const PdfNumber(4), // Print
      'T': PdfString.utf16(author),
      'NM': PdfString.utf16(annotation.id),
      'M': PdfString(Uint8List.fromList(pdfDate.codeUnits)),
      'P': pageRef,
    });
    writer.replaceObject(annotNumber, annotDict);
    newRefs.add(PdfRef(annotNumber));
  }

  if (newRefs.isEmpty) {
    throw PdfInkExportException('所有批注的笔迹都是空的');
  }

  // 把新注释挂到页面的 /Annots 上。
  // /Annots 可能是间接引用的数组对象，也可能直接写在页面字典里。
  final annotsObject = pageDict.entries['Annots'];
  final resolved = reader.deref(annotsObject);

  if (annotsObject is PdfRef && resolved is PdfArray) {
    // 情形一：/Annots 是独立的数组对象 —— 重写该对象
    final items = List<PdfObject>.from(resolved.items)..addAll(newRefs);
    writer.replaceObject(annotsObject.number, PdfArray(items));
  } else if (annotsObject == null) {
    // 情形二：页面没有 /Annots —— 重写页面字典并加上
    final updated = PdfDict(Map.of(pageDict.entries))..['Annots'] = PdfArray(List.of(newRefs));
    writer.replaceObject(pageRef.number, updated);
  } else if (annotsObject is PdfArray) {
    // 情形三：/Annots 是直接数组 —— 重写页面字典
    final items = List<PdfObject>.from(annotsObject.items)..addAll(newRefs);
    final updated = PdfDict(Map.of(pageDict.entries))..['Annots'] = PdfArray(items);
    writer.replaceObject(pageRef.number, updated);
  } else {
    throw PdfInkExportException('/Annots 的形式无法处理：${annotsObject.runtimeType}');
  }

  final output = writer.finish(startXref);
  File(outputPath).writeAsBytesSync(output, flush: true);

  return InkExportResult(
    outputPath: outputPath,
    pageNumber: pageNumber,
    annotationCount: newRefs.length,
    strokeCount: strokeCount,
    bytes: output.length,
  );
}

/// 把墨迹**直接写回原 PDF 文件**（设计文档 3.3 的目标形态）。
///
/// ## 为什么要「先生成再校验最后写」
///
/// macOS 沙箱只授权了用户选中的**那一个文件**，不含其所在目录，
/// 因此无法用「写临时文件再 rename」的原子替换（那需要创建同级文件）。
/// 只能原地覆盖，而 `FileMode.write` 会先截断 —— 一旦写入中途失败，
/// 原文件就废了。
///
/// 所以流程刻意设计成：
/// 1. **在内存中**生成完整的新 PDF
/// 2. 用我们自己的解析器**校验**生成结果（页数一致、注释确实在里面）
/// 3. 备份原文件到应用容器
/// 4. 才写入目标文件
///
/// 任何一步失败都在touch原文件之前中止。
Future<InkExportResult> writeInkIntoPdf({
  required String pdfPath,
  required int pageNumber,
  required List<InkAnnotationInput> annotations,
  String author = 'ebook studio',
  String? backupDir,
  DateTime? now,
}) async {
  final source = File(pdfPath);
  if (!source.existsSync()) {
    throw PdfInkExportException('文件不存在：$pdfPath');
  }

  // 1. 先在内存里生成（写到不存在的路径也不会动原文件）
  final tempPath = '$pdfPath.ebook-studio-export';
  final result = exportInkAnnotations(
    sourcePath: pdfPath,
    outputPath: tempPath,
    pageNumber: pageNumber,
    annotations: annotations,
    author: author,
    now: now,
  );

  // 2. 校验生成结果：能被解析、页数一致、注释确实在
  final generated = File(tempPath).readAsBytesSync();
  try {
    final reader = PdfFileReader.fromBytes(generated);
    final original = PdfFileReader.fromBytes(source.readAsBytesSync());
    if (reader.collectPages().length != original.collectPages().length) {
      throw PdfInkExportException('校验失败：生成文件的页数与原文件不一致');
    }
    final page = reader.resolve(reader.collectPages()[pageNumber - 1]) as PdfDict;
    final annots = reader.dictGet(page, 'Annots');
    if (annots is! PdfArray || annots.items.isEmpty) {
      throw PdfInkExportException('校验失败：生成文件里找不到注释');
    }
  } on PdfSyntaxException catch (error) {
    throw PdfInkExportException('校验失败：生成的 PDF 无法解析（$error）');
  }

  // 3. 备份原文件
  String? backupPath;
  if (backupDir != null) {
    try {
      final dir = Directory(backupDir)..createSync(recursive: true);
      final name = pdfPath.split(RegExp(r'[/\\]')).last;
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      backupPath = '${dir.path}/$name.$stamp.bak';
      source.copySync(backupPath);
    } on FileSystemException {
      backupPath = null; // 备份失败不阻断，但要在结果里如实反映
    }
  }

  // 4. 写回原文件
  try {
    source.writeAsBytesSync(generated, flush: true);
  } on FileSystemException catch (error) {
    // 写失败时尽量用备份恢复
    if (backupPath != null && File(backupPath).existsSync()) {
      try {
        source.writeAsBytesSync(File(backupPath).readAsBytesSync(), flush: true);
      } on FileSystemException {
        // 恢复也失败：把备份路径告诉用户
      }
    }
    throw PdfInkExportException(
      '写入 PDF 失败：${error.osError?.message ?? error.message}'
      '${backupPath != null ? '\n原文件备份在：$backupPath' : ''}',
    );
  } finally {
    final temp = File(tempPath);
    if (temp.existsSync()) temp.deleteSync();
  }

  return InkExportResult(
    outputPath: pdfPath,
    pageNumber: result.pageNumber,
    annotationCount: result.annotationCount,
    strokeCount: result.strokeCount,
    bytes: generated.length,
    backupPath: backupPath,
  );
}

/// [writeInkIntoPdf] 的同步版本（内部实现本就是同步的文件操作）。
///
/// 单独暴露是为了让单元测试能直接断言「失败时原文件未被改动」，
/// 不引入 async 时序的不确定性。
InkExportResult writeInkIntoPdfSync({
  required String pdfPath,
  required int pageNumber,
  required List<InkAnnotationInput> annotations,
  String author = 'ebook studio',
  String? backupDir,
  DateTime? now,
}) {
  final source = File(pdfPath);
  if (!source.existsSync()) {
    throw PdfInkExportException('文件不存在：$pdfPath');
  }

  final tempPath = '$pdfPath.ebook-studio-export';
  final result = exportInkAnnotations(
    sourcePath: pdfPath,
    outputPath: tempPath,
    pageNumber: pageNumber,
    annotations: annotations,
    author: author,
    now: now,
  );

  final generated = File(tempPath).readAsBytesSync();
  try {
    final reader = PdfFileReader.fromBytes(generated);
    final original = PdfFileReader.fromBytes(source.readAsBytesSync());
    if (reader.collectPages().length != original.collectPages().length) {
      throw PdfInkExportException('校验失败：生成文件的页数与原文件不一致');
    }
    final page = reader.resolve(reader.collectPages()[pageNumber - 1]) as PdfDict;
    final annots = reader.dictGet(page, 'Annots');
    if (annots is! PdfArray || annots.items.isEmpty) {
      throw PdfInkExportException('校验失败：生成文件里找不到注释');
    }
  } on PdfSyntaxException catch (error) {
    throw PdfInkExportException('校验失败：生成的 PDF 无法解析（$error）');
  } finally {
    final temp = File(tempPath);
    if (temp.existsSync()) temp.deleteSync();
  }

  String? backupPath;
  if (backupDir != null) {
    try {
      final dir = Directory(backupDir)..createSync(recursive: true);
      final name = pdfPath.split(RegExp(r'[/\\]')).last;
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      backupPath = '${dir.path}/$name.$stamp.bak';
      source.copySync(backupPath);
    } on FileSystemException {
      backupPath = null;
    }
  }

  try {
    source.writeAsBytesSync(generated, flush: true);
  } on FileSystemException catch (error) {
    if (backupPath != null && File(backupPath).existsSync()) {
      try {
        source.writeAsBytesSync(File(backupPath).readAsBytesSync(), flush: true);
      } on FileSystemException {
        // 恢复失败：下面把备份路径告诉用户
      }
    }
    throw PdfInkExportException(
      '写入 PDF 失败：${error.osError?.message ?? error.message}'
      '${backupPath != null ? '\n原文件备份在：$backupPath' : ''}',
    );
  }

  return InkExportResult(
    outputPath: pdfPath,
    pageNumber: result.pageNumber,
    annotationCount: result.annotationCount,
    strokeCount: result.strokeCount,
    bytes: generated.length,
    backupPath: backupPath,
  );
}

/// 一条待导出的批注。
class InkAnnotationInput {
  const InkAnnotationInput({
    required this.id,
    required this.color,
    required this.strokes,
  });

  /// 批注 id，写入 `/NM`，用于避免重复导入。
  final String id;
  final Color color;
  final List<InkStroke> strokes;
}

/// 导出失败。
class PdfInkExportException implements Exception {
  PdfInkExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 颜色 → PDF 的 0~1 RGB 分量。
List<double> _colorComponents(Color color) => [
      (color.r * 255).round() / 255,
      (color.g * 255).round() / 255,
      (color.b * 255).round() / 255,
    ];

double _round(double value) => (value * 100).roundToDouble() / 100;

/// PDF 日期串：`D:YYYYMMDDHHmmSSZ`
String _pdfDate(DateTime utc) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'D:${utc.year}${two(utc.month)}${two(utc.day)}'
      '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}


/// 累积包围盒（PDF 坐标）。
class _Bounds {
  double left = double.infinity;
  double bottom = double.infinity;
  double right = double.negativeInfinity;
  double top = double.negativeInfinity;

  void include(double x, double y) {
    if (x < left) left = x;
    if (x > right) right = x;
    if (y < bottom) bottom = y;
    if (y > top) top = y;
  }

  void expand(double amount) {
    left -= amount;
    bottom -= amount;
    right += amount;
    top += amount;
  }
}
