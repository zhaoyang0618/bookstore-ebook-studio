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

/// 生成「含原生 `/Ink` 注释」的 PDF 字节，**不写任何文件**。
///
/// 之所以先把生成与落盘分开：macOS 沙箱只授权用户选中的那一个文件，
/// **不含它所在目录**，所以「先写临时文件再改名」这种做法根本行不通
///（连同级临时文件都创建不了）。在内存里生成好再一次性写入，
/// 既避开沙箱限制，也避免了写的中间态。
({Uint8List bytes, int annotationCount, int strokeCount}) buildInkAnnotatedBytes({
  required String sourcePath,
  required int pageNumber,
  required List<InkAnnotationInput> annotations,
  String author = 'ebook studio',
  DateTime? now,
}) {
  if (annotations.isEmpty) {
    throw PdfInkExportException('没有要导出的墨迹');
  }

  final Uint8List data;
  try {
    data = File(sourcePath).readAsBytesSync();
  } on FileSystemException catch (error) {
    throw PdfInkExportException('读取 PDF 失败：${error.osError?.message ?? error.message}');
  }
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

    final rect = [
      _round(bounds.left),
      _round(bounds.bottom),
      _round(bounds.right),
      _round(bounds.top),
    ];

    // ---- 外观流（/AP）----
    //
    // 为什么必须有它：**macOS 预览（PDFKit）不会自己合成墨迹外观**，
    // 只认 /AP；没有 /AP 时墨迹在预览里完全看不见。
    // PDF.js / Chrome / Acrobat 能读 /InkList 自己画，所以只在预览上暴露问题。
    // 加上 /AP 对它们也只是改成用同一份外观，行为一致。
    final apNumber = writer.addStream(
      PdfDict({
        'Type': const PdfName('XObject'),
        'Subtype': const PdfName('Form'),
        'FormType': const PdfNumber(1),
        // BBox 用页面的绝对坐标（Matrix 保持单位阵），
        // 这样外观流里的坐标与 /InkList 完全一致，便于对照排查。
        'BBox': PdfArray(rect.map((v) => PdfNumber(v)).toList()),
        'Resources': PdfDict({
          if (annotation.color.a < 1)
            'ExtGState': PdfDict({
              'GS0': PdfDict({
                'CA': PdfNumber(annotation.color.a),
                'BM': const PdfName('Multiply'),
              }),
            }),
        }),
      }),
      _appearanceContent(
        strokes: inkList,
        color: color,
        width: width,
        alpha: annotation.color.a,
      ),
    );

    final annotNumber = writer.allocate();
    final annotDict = PdfDict({
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Ink'),
      'Rect': PdfArray(rect.map((v) => PdfNumber(v)).toList()),
      'InkList': PdfArray(inkList),
      'C': PdfArray(color.map((c) => PdfNumber(c)).toList()),
      'Border': PdfArray([const PdfNumber(0), const PdfNumber(0), PdfNumber(_round(width))]),
      // /BS 是 /Border 的现代替代写法，部分阅读器（含 Preview）更认它
      'BS': PdfDict({
        'Type': const PdfName('Border'),
        'W': PdfNumber(_round(width)),
        'S': const PdfName('S'),
      }),
      'AP': PdfDict({'N': PdfRef(apNumber)}),
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
  return (bytes: output, annotationCount: newRefs.length, strokeCount: strokeCount);
}

/// 把某页的墨迹导出成原生 `/Ink` 注释，写到 [outputPath]。
///
/// 采用**增量更新**：不重写原文件内容，只在尾部追加。
/// 失败抛 [PdfInkExportException]。
InkExportResult exportInkAnnotations({
  required String sourcePath,
  required String outputPath,
  required int pageNumber,
  required List<InkAnnotationInput> annotations,
  String author = 'ebook studio',
  DateTime? now,
}) {
  final built = buildInkAnnotatedBytes(
    sourcePath: sourcePath,
    pageNumber: pageNumber,
    annotations: annotations,
    author: author,
    now: now,
  );
  try {
    File(outputPath).writeAsBytesSync(built.bytes, flush: true);
  } on FileSystemException catch (error) {
    throw PdfInkExportException(
      '写入失败（${_describeFileError(error)}）：$outputPath',
    );
  }
  return InkExportResult(
    outputPath: outputPath,
    pageNumber: pageNumber,
    annotationCount: built.annotationCount,
    strokeCount: built.strokeCount,
    bytes: built.bytes.length,
  );
}

/// 把文件系统错误翻译成可操作的中文说明。
String _describeFileError(FileSystemException error) {
  final code = error.osError?.errorCode;
  final message = error.osError?.message ?? error.message;
  return switch (code) {
    1 => '权限不足，macOS 沙箱不允许写入该位置',
    13 => '权限不足，macOS 沙箱不允许写入该位置',
    2 => '目录或文件不存在',
    28 => '磁盘空间不足',
    _ => message,
  };
}

/// 把墨迹**直接写回原 PDF 文件**（设计文档 3.3 的目标形态）。
///
/// ## 沙箱约束决定了实现方式
///
/// macOS 只授权用户选中的**那一个文件**，不含其所在目录。
/// 所以：
/// - ❌ 不能「写临时文件再 rename」—— 连同级临时文件都创建不了
/// - ❌ 不能「另存到同目录」—— 同样需要目录权限
/// - ✅ 只能**原地覆盖**那个已被授权的文件
///
/// 原地覆盖的风险是「写到一半失败会毁掉原文件」，因此流程是：
/// 1. **在内存中**生成完整的新 PDF（不碰磁盘）
/// 2. 用我们自己的解析器**校验**（页数一致、注释确实在）
/// 3. 备份原文件到应用容器
/// 4. 才一次性写入目标文件
///
/// 任一步失败都在碰原文件之前中止；写入失败会用备份回滚。
///
/// 失败一律抛 [PdfInkExportException]（含可操作的中文原因），
/// 不会让 `FileSystemException` 直接逃逸出去。
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

  // 1. 内存中生成
  final built = buildInkAnnotatedBytes(
    sourcePath: pdfPath,
    pageNumber: pageNumber,
    annotations: annotations,
    author: author,
    now: now,
  );

  // 2. 校验生成结果
  try {
    final reader = PdfFileReader.fromBytes(built.bytes);
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
  } on FileSystemException catch (error) {
    throw PdfInkExportException('校验时读取文件失败：${_describeFileError(error)}');
  }

  // 3. 备份原文件（失败不阻断，但要在结果里如实反映）
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

  // 4. 写回
  try {
    source.writeAsBytesSync(built.bytes, flush: true);
  } on FileSystemException catch (error) {
    if (backupPath != null && File(backupPath).existsSync()) {
      try {
        source.writeAsBytesSync(File(backupPath).readAsBytesSync(), flush: true);
      } on FileSystemException {
        // 恢复也失败：下面把备份路径告诉用户，让他手动处理
      }
    }
    throw PdfInkExportException(
      '写入 PDF 失败：${_describeFileError(error)}'
      '${backupPath != null ? '\n原文件已备份在：$backupPath' : ''}',
    );
  }

  return InkExportResult(
    outputPath: pdfPath,
    pageNumber: pageNumber,
    annotationCount: built.annotationCount,
    strokeCount: built.strokeCount,
    bytes: built.bytes.length,
    backupPath: backupPath,
  );
}

/// [writeInkIntoPdfSync] 的异步包装（文件操作本身是同步的）。
Future<InkExportResult> writeInkIntoPdf({
  required String pdfPath,
  required int pageNumber,
  required List<InkAnnotationInput> annotations,
  String author = 'ebook studio',
  String? backupDir,
  DateTime? now,
}) async =>
    writeInkIntoPdfSync(
      pdfPath: pdfPath,
      pageNumber: pageNumber,
      annotations: annotations,
      author: author,
      backupDir: backupDir,
      now: now,
    );

/// 生成外观流的内容（PDF 内容流语法）。
///
/// [strokes] 是已经转成 PDF 坐标的 `/InkList` 结构。
/// 坐标直接用页面绝对坐标，与 `/InkList` 一致。
List<int> _appearanceContent({
  required List<PdfObject> strokes,
  required List<double> color,
  required double width,
  required double alpha,
}) {
  final buffer = StringBuffer();
  buffer.writeln('q');
  if (alpha < 1) buffer.writeln('/GS0 gs');
  buffer.writeln('${_n(color[0])} ${_n(color[1])} ${_n(color[2])} RG');
  buffer.writeln('${_n(width)} w');
  buffer.writeln('1 J'); // 圆头
  buffer.writeln('1 j'); // 圆角连接

  for (final stroke in strokes) {
    if (stroke is! PdfArray || stroke.items.length < 4) continue;
    final numbers = stroke.items.whereType<PdfNumber>().map((n) => n.value.toDouble()).toList();
    if (numbers.length < 4) continue;
    buffer.write('${_n(numbers[0])} ${_n(numbers[1])} m\n');
    for (var i = 2; i + 1 < numbers.length; i += 2) {
      buffer.write('${_n(numbers[i])} ${_n(numbers[i + 1])} l\n');
    }
    buffer.writeln('S');
  }
  buffer.writeln('Q');
  return buffer.toString().codeUnits;
}

/// 紧凑的数字格式（PDF 内容流用）。
String _n(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
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
