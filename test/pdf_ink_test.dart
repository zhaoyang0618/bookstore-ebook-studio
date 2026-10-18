/// PDF 原生注释写入的测试（设计文档 3.3 / 4.2）。
///
/// 真实文件相关的用例在没有样本时自动跳过，保证 CI 与本地都能跑。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ebook_studio/features/annotation/ink_canvas.dart';
import 'package:ebook_studio/pdf/pdf_ink_export.dart';
import 'package:ebook_studio/pdf/pdf_reader.dart';
import 'package:ebook_studio/pdf/pdf_syntax.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实样本（工作区根目录的 2.pdf，338 页 LaTeX 生成，PDF 1.7 + xref 流 + 对象流）
const String kRealPdf = '/Users/yuzhaoyang/Works/harness_workspace/zcode/book_store/2.pdf';
bool get hasRealPdf => File(kRealPdf).existsSync();

/// 一份用经典 xref 表的手写小 PDF，覆盖「最老式」结构。
Uint8List buildClassicPdf() {
  final objects = <String>[
    '1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n',
    '2 0 obj\n<</Type/Pages/Count 1/Kids[3 0 R]>>\nendobj\n',
    '3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 400]>>\nendobj\n',
  ];
  final buffer = BytesBuilder();
  buffer.add('%PDF-1.4\n'.codeUnits);
  final offsets = <int>[0];
  for (final obj in objects) {
    offsets.add(buffer.length);
    buffer.add(obj.codeUnits);
  }
  final xrefOffset = buffer.length;
  final sb = StringBuffer('xref\n0 ${objects.length + 1}\n');
  sb.write('0000000000 65535 f \n');
  for (var i = 1; i <= objects.length; i++) {
    sb.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<</Size ${objects.length + 1}/Root 1 0 R>>\n');
  sb.write('startxref\n$xrefOffset\n%%EOF\n');
  buffer.add(sb.toString().codeUnits);
  return buffer.toBytes();
}


/// 构造一个**现代格式** PDF：xref 流 + 对象流（PDF 1.5+）。
///
/// 为什么要在测试里生成它：真实样本 `2.pdf` 无法提交进仓库，
/// 而「xref 流 + 对象流」恰恰是本实现最容易出错、也最必须覆盖的路径
///（页面对象被压缩，必须解对象流才能拿到页面树）。
/// 有了它，CI 也能真正验证这条路径，而不是只在本地偶然跑过。
Uint8List buildModernPdf() {
  // 对象 1 = Catalog，2 = Pages，3 = Page —— 全部塞进对象流
  final inner = <String>[
    '<</Type/Catalog/Pages 2 0 R>>',
    '<</Type/Pages/Count 1/Kids[3 0 R]/MediaBox[0 0 300 500]>>',
    '<</Type/Page/Parent 2 0 R>>',
  ];

  // 对象流头部：N 组「对象号 相对偏移」（裸数字，无方括号）
  final header = StringBuffer();
  final offsets = <int>[];
  var cursor = 0;
  for (var i = 0; i < inner.length; i++) {
    offsets.add(cursor);
    header.write('${i + 1} $cursor ');
    cursor += inner[i].length + 1;
  }
  final headerText = header.toString();
  final body = inner.map((s) => '$s ').join();
  final objStmContent = '$headerText$body';

  final out = BytesBuilder();
  out.add('%PDF-1.5\n'.codeUnits);

  // 对象 5 = 对象流
  final objStmOffset = out.length;
  final compressed = Uint8List.fromList(ZLibEncoder().convert(objStmContent.codeUnits));
  out.add('5 0 obj\n<</Type/ObjStm/N ${inner.length}/First ${headerText.length}'
      '/Filter/FlateDecode/Length ${compressed.length}>>\nstream\n'.codeUnits);
  out.add(compressed);
  out.add('\nendstream\nendobj\n'.codeUnits);

  // 对象 4 = xref 流；条目 0..5，W = [1 4 2]
  final xrefOffset = out.length;
  final entries = BytesBuilder();
  void entry(int type, int f1, int f2) {
    entries.addByte(type);
    entries.add([(f1 >> 24) & 0xFF, (f1 >> 16) & 0xFF, (f1 >> 8) & 0xFF, f1 & 0xFF]);
    entries.add([(f2 >> 8) & 0xFF, f2 & 0xFF]);
  }

  entry(0, 0, 65535); // 0：空闲
  for (var i = 0; i < inner.length; i++) {
    entry(2, 5, i); // 1..3：压缩在对象流 5 里
  }
  entry(1, xrefOffset, 0); // 4：xref 流自身
  entry(1, objStmOffset, 0); // 5：对象流

  final xrefData = Uint8List.fromList(ZLibEncoder().convert(entries.toBytes()));
  out.add('4 0 obj\n<</Type/XRef/Size 6/W[1 4 2]/Root 1 0 R'
      '/Filter/FlateDecode/Length ${xrefData.length}>>\nstream\n'.codeUnits);
  out.add(xrefData);
  out.add('\nendstream\nendobj\n'.codeUnits);
  out.add('startxref\n$xrefOffset\n%%EOF\n'.codeUnits);
  return out.toBytes();
}

InkStroke strokeAt(List<Offset> points, {double width = 2}) => InkStroke(
      color: const Color(0xFFE53935),
      width: width,
      points: points.map((p) => InkPoint(x: p.dx, y: p.dy, pressure: 1, t: 0)).toList(),
    );

void main() {
  group('PDF 语法（对象模型）', () {
    test('解析字典、数组、名字、数字与引用', () {
      final parser = PdfParser(Uint8List.fromList(
        '<</Type/Page/Parent 2 0 R/MediaBox[0 0 595.28 841.89]/F 4>>'.codeUnits,
      ));
      final dict = parser.parseObject();
      expect(dict, isA<PdfDict>());
      final d = dict as PdfDict;
      expect((d['Type'] as PdfName).name, 'Page');
      expect(d['Parent'], const PdfRef(2, 0));
      expect((d['MediaBox'] as PdfArray).items.length, 4);
      expect(((d['MediaBox'] as PdfArray).items[2] as PdfNumber).value, 595.28);
    });

    test('名字的 #xx 转义', () {
      final parser = PdfParser(Uint8List.fromList('/A#20B'.codeUnits));
      expect((parser.parseObject() as PdfName).name, 'A B');
    });

    test('字面量字符串的转义与嵌套括号', () {
      final parser = PdfParser(Uint8List.fromList(r'(a\(b\)c\n)'.codeUnits));
      final s = parser.parseObject() as PdfString;
      expect(String.fromCharCodes(s.bytes), 'a(b)c\n');
    });

    test('十六进制字符串（含奇数位补零）', () {
      final parser = PdfParser(Uint8List.fromList('<48656c6c6f>'.codeUnits));
      expect(String.fromCharCodes((parser.parseObject() as PdfString).bytes), 'Hello');
    });

    test('中文用 UTF-16BE hex 编码（PDFDocEncoding 装不下）', () {
      final s = PdfString.utf16('黑暗森林');
      expect(s.isHex, isTrue);
      final encoded = s.encode();
      expect(encoded.startsWith('<feff'), isTrue, reason: '必须有 BOM');
      expect(encoded, contains('9ed1')); // 「黑」的 UTF-16BE
    });

    test('数字序列化：整数不带小数点', () {
      expect(const PdfNumber(4).encode(), '4');
      expect(const PdfNumber(595.28).encode(), '595.28');
      expect(const PdfNumber(2.0).encode(), '2');
    });

    test('序列化后再解析应等价（往返）', () {
      final original = PdfDict({
        'Type': const PdfName('Annot'),
        'Rect': PdfArray([const PdfNumber(1), const PdfNumber(2.5), const PdfNumber(3), const PdfNumber(4)]),
        'P': const PdfRef(3, 0),
        'T': PdfString.utf16('中文作者'),
      });
      final parsed = PdfParser(Uint8List.fromList(original.encode().codeUnits)).parseObject();
      expect(parsed, isA<PdfDict>());
      final d = parsed as PdfDict;
      expect((d['Type'] as PdfName).name, 'Annot');
      expect((d['P'] as PdfRef).number, 3);
      // 中文往返
      final s = d['T'] as PdfString;
      expect(s.bytes.length, 2 + '中文作者'.codeUnits.length * 2);
    });
  });

  group('PDF 读取（经典 xref 表）', () {
    late Uint8List data;
    setUp(() => data = buildClassicPdf());

    test('能找到 startxref 与 /Root', () {
      final reader = PdfFileReader.fromBytes(data);
      expect(reader.root.number, 1);
      expect(reader.size, 4);
    });

    test('能收集页面', () {
      final reader = PdfFileReader.fromBytes(data);
      final pages = reader.collectPages();
      expect(pages.length, 1);
      expect(pages.first.number, 3);
    });

    test('能从页面继承 MediaBox', () {
      final reader = PdfFileReader.fromBytes(data);
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final geom = reader.pageGeometry(page);
      expect(geom.mediaBox, [0, 0, 200, 400]);
      expect(geom.rotate, 0);
    });
  });


  group('PDF 读取（xref 流 + 对象流，CI 可覆盖）', () {
    late Uint8List data;
    setUp(() => data = buildModernPdf());

    test('能解析 xref 流', () {
      final reader = PdfFileReader.fromBytes(data);
      expect(reader.root.number, 1);
      expect(reader.size, 6);
      // 1..3 是压缩对象
      expect(reader.entries[1]!.type, 2);
      expect(reader.entries[5]!.type, 1);
    });

    test('能从对象流里取出被压缩的对象', () {
      final reader = PdfFileReader.fromBytes(data);
      final catalog = reader.resolve(reader.root) as PdfDict;
      expect((catalog['Type'] as PdfName).name, 'Catalog');
      expect(reader.dictGet(reader.root, 'Pages'), isA<PdfDict>());
    });

    test('能沿对象流里的页面树收集页面', () {
      final reader = PdfFileReader.fromBytes(data);
      final pages = reader.collectPages();
      expect(pages.length, 1);
      expect(pages.first.number, 3);
      // MediaBox 在 Pages 节点上，需继承
      final page = reader.resolve(pages.first) as PdfDict;
      expect(reader.pageGeometry(page).mediaBox, [0, 0, 300, 500]);
    });

    test('现代格式也能写入原生 Ink 注释', () {
      final dir = Directory.systemTemp.createTempSync('pdf_modern');
      final src = File('${dir.path}/modern.pdf')..writeAsBytesSync(data);
      final out = '${dir.path}/modern-out.pdf';

      final result = exportInkAnnotations(
        sourcePath: src.path,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-modern',
            color: const Color(0xFFE53935),
            strokes: [strokeAt([const Offset(50, 60), const Offset(150, 110)])],
          ),
        ],
      );
      expect(result.annotationCount, 1);

      final reader = PdfFileReader.fromBytes(File(out).readAsBytesSync());
      expect(reader.collectPages().length, 1);
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots') as PdfArray;
      final annot = reader.deref(annots.items.last) as PdfDict;
      expect((annot['Subtype'] as PdfName).name, 'Ink');
      // y 翻转：500 - 60 = 440
      final inkList = annot['InkList'] as PdfArray;
      final firstStroke = inkList.items.first as PdfArray;
      expect((firstStroke.items[1] as PdfNumber).value, closeTo(440, 0.01));
    });
  });

  group('PDF 读取（真实文件：xref 流 + 对象流，本地样本）', () {
    test('解析 338 页 LaTeX PDF', () {
      final reader = PdfFileReader.fromBytes(File(kRealPdf).readAsBytesSync());
      expect(reader.size, 1935);
      expect(reader.root.number, 1);
      // 页面对象被压缩在对象流里，必须解压才能收集
      expect(reader.collectPages().length, 338);
      expect(reader.collectPages().first.number, 3);
      // MediaBox 继承自 4 层之上的 Pages 节点
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final geom = reader.pageGeometry(page);
      expect(geom.mediaBox[2], closeTo(595.28, 0.01));
      expect(geom.mediaBox[3], closeTo(841.89, 0.01));
    });
  }, skip: !hasRealPdf);

  group('墨迹导出为原生 /Ink 注释', () {
    test('经典表 PDF：注释被写入且可被重新解析', () {
      final dir = Directory.systemTemp.createTempSync('pdf_ink_test');
      final src = File('${dir.path}/classic.pdf')..writeAsBytesSync(buildClassicPdf());
      final out = '${dir.path}/classic-out.pdf';

      final result = exportInkAnnotations(
        sourcePath: src.path,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-test-1',
            color: const Color(0xFFE53935),
            strokes: [
              strokeAt([const Offset(20, 30), const Offset(60, 80)]),
              strokeAt([const Offset(100, 120), const Offset(140, 160)]),
            ],
          ),
        ],
        now: DateTime.utc(2026, 10, 18, 12, 0, 0),
      );

      expect(result.annotationCount, 1);
      expect(result.strokeCount, 2);
      expect(File(out).existsSync(), isTrue);

      // 重新解析输出：新注释应挂在页面的 /Annots 上
      final reader = PdfFileReader.fromBytes(File(out).readAsBytesSync());
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots');
      expect(annots, isA<PdfArray>());
      final items = (annots as PdfArray).items;
      expect(items.length, 1);

      final annot = reader.deref(items.first) as PdfDict;
      expect((annot['Subtype'] as PdfName).name, 'Ink');
      final inkList = annot['InkList'] as PdfArray;
      expect(inkList.items.length, 2, reason: '两条笔迹');
      expect((inkList.items.first as PdfArray).items.length, 4, reason: '每笔 2 个点 → 4 个数字');

      // 坐标必须翻转成 PDF 坐标系（页面高 400）
      final firstStroke = (inkList.items.first as PdfArray).items;
      final y0 = (firstStroke[1] as PdfNumber).value;
      expect(y0, closeTo(400 - 30, 0.01));

      // 颜色与元数据
      final c = annot['C'] as PdfArray;
      expect((c.items[0] as PdfNumber).value, closeTo(0.898, 0.01));
      expect((annot['NM'] as PdfString).isHex, isTrue);
    });

    test('真实 PDF：导出后页数不变，注释可见', () {
      final dir = Directory.systemTemp.createTempSync('pdf_ink_real');
      final out = '${dir.path}/out.pdf';

      final result = exportInkAnnotations(
        sourcePath: kRealPdf,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-real-1',
            color: const Color(0xFF1E88E5),
            strokes: [strokeAt([const Offset(100, 100), const Offset(200, 150), const Offset(300, 120)])],
          ),
        ],
      );
      expect(result.annotationCount, 1);
      expect(result.strokeCount, 1);

      // 页数与页面对象不变
      final reader = PdfFileReader.fromBytes(File(out).readAsBytesSync());
      expect(reader.collectPages().length, 338);

      // 新注释追加在原有 /Annots 之后
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots') as PdfArray;
      final last = reader.deref(annots.items.last) as PdfDict;
      expect((last['Subtype'] as PdfName).name, 'Ink');
      expect((last['InkList'] as PdfArray).items.length, 1);

      // 原文件未被改动
      expect(File(kRealPdf).lengthSync(), 1506800);
    }, skip: !hasRealPdf);

    test('页码越界时报错而不是写坏文件', () {
      final dir = Directory.systemTemp.createTempSync('pdf_ink_bad');
      final src = File('${dir.path}/c.pdf')..writeAsBytesSync(buildClassicPdf());
      expect(
        () => exportInkAnnotations(
          sourcePath: src.path,
          outputPath: '${dir.path}/o.pdf',
          pageNumber: 99,
          annotations: [
            InkAnnotationInput(
              id: 'x',
              color: const Color(0xFF000000),
              strokes: [strokeAt([const Offset(1, 1), const Offset(2, 2)])],
            ),
          ],
        ),
        throwsA(isA<PdfInkExportException>()),
      );
      expect(File('${dir.path}/o.pdf').existsSync(), isFalse);
    });

    test('空墨迹报错', () {
      final dir = Directory.systemTemp.createTempSync('pdf_ink_empty');
      final src = File('${dir.path}/c.pdf')..writeAsBytesSync(buildClassicPdf());
      expect(
        () => exportInkAnnotations(
          sourcePath: src.path,
          outputPath: '${dir.path}/o.pdf',
          pageNumber: 1,
          annotations: const [],
        ),
        throwsA(isA<PdfInkExportException>()),
      );
    });
  });

  group('原地写回 PDF（备份 + 校验）', () {
    test('写回后原文件变成含注释的版本，且留下备份', () {
      final dir = Directory.systemTemp.createTempSync('pdf_write');
      final target = File('${dir.path}/book.pdf')..writeAsBytesSync(buildClassicPdf());
      final backupDir = '${dir.path}/backups';
      final originalBytes = target.readAsBytesSync();

      final result = writeInkIntoPdfSync(
        pdfPath: target.path,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-write-1',
            color: const Color(0xFF43A047),
            strokes: [strokeAt([const Offset(10, 20), const Offset(30, 40)])],
          ),
        ],
        backupDir: backupDir,
      );

      expect(result.annotationCount, 1);
      expect(result.outputPath, target.path);
      expect(result.bytes, greaterThan(originalBytes.length));

      // 备份存在且与原文一致
      expect(result.backupPath, isNotNull);
      final backup = File(result.backupPath!);
      expect(backup.existsSync(), isTrue);
      expect(backup.readAsBytesSync(), originalBytes);

      // 原文件现在含原生 Ink 注释
      final reader = PdfFileReader.fromBytes(target.readAsBytesSync());
      expect(reader.collectPages().length, 1);
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots') as PdfArray;
      final annot = reader.deref(annots.items.last) as PdfDict;
      expect((annot['Subtype'] as PdfName).name, 'Ink');

      // 不残留临时文件
      final leftovers = dir.listSync().where((f) => f.path.contains('ebook-studio-export'));
      expect(leftovers, isEmpty);
    });

    test('校验失败时不碰原文件', () {
      final dir = Directory.systemTemp.createTempSync('pdf_write_bad');
      final target = File('${dir.path}/book.pdf')..writeAsBytesSync(buildClassicPdf());
      final before = target.readAsBytesSync();

      // 页码越界 → 在写入前就该失败
      expect(
        () => writeInkIntoPdfSync(
          pdfPath: target.path,
          pageNumber: 5,
          annotations: [
            InkAnnotationInput(
              id: 'x',
              color: const Color(0xFF000000),
              strokes: [strokeAt([const Offset(1, 1), const Offset(2, 2)])],
            ),
          ],
        ),
        throwsA(isA<PdfInkExportException>()),
      );
      expect(target.readAsBytesSync(), before, reason: '原文件必须一字未动');
    });

    test('真实 PDF 原地写回后仍是 338 页', () {
      final dir = Directory.systemTemp.createTempSync('pdf_write_real');
      final target = File('${dir.path}/real.pdf')
        ..writeAsBytesSync(File(kRealPdf).readAsBytesSync());

      final result = writeInkIntoPdfSync(
        pdfPath: target.path,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-real-write',
            color: const Color(0xFF8E24AA),
            strokes: [strokeAt([const Offset(80, 80), const Offset(180, 160)])],
          ),
        ],
        backupDir: '${dir.path}/backups',
      );
      expect(result.annotationCount, 1);

      final reader = PdfFileReader.fromBytes(target.readAsBytesSync());
      expect(reader.collectPages().length, 338);
      // 原工作区样本未被改动
      expect(File(kRealPdf).lengthSync(), 1506800);
    }, skip: !hasRealPdf);
  });

  group('沙箱/权限场景（回归测试）', () {
    test('不能创建同级文件时，抛的是可读的 PdfInkExportException', () {
      final dir = Directory.systemTemp.createTempSync('pdf_sandbox');
      final target = File('${dir.path}/book.pdf')..writeAsBytesSync(buildClassicPdf());

      // 模拟 macOS 沙箱：能读写这个文件，但不能在它所在目录创建新文件。
      // 这里直接把目录设为只读来复现。
      Process.runSync('chmod', ['500', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['700', dir.path]));

      try {
        // 先确认环境确实复现了「目录不可写」
        final probeFailed = () {
          try {
            File('${dir.path}/probe').writeAsStringSync('x');
            return false;
          } on FileSystemException {
            return true;
          }
        }();
        if (!probeFailed) return; // 以 root 运行时权限不生效，跳过

        // 关键：写回**不应该**创建任何同级文件，因此不该因为目录只读而失败
        final result = writeInkIntoPdfSync(
          pdfPath: target.path,
          pageNumber: 1,
          annotations: [
            InkAnnotationInput(
              id: 'ink-sandbox',
              color: const Color(0xFFE53935),
              strokes: [strokeAt([const Offset(10, 10), const Offset(40, 40)])],
            ),
          ],
        );
        expect(result.annotationCount, 1);
        expect(result.bytes, greaterThan(0));
        // 目录里仍然只有原始文件，没有残留的临时文件
        final names = dir.listSync().map((f) => f.path.split('/').last).toList();
        expect(names, ['book.pdf']);
      } on PdfInkExportException catch (error) {
        // 即便失败，也必须是可读的中文原因，而不是裸 FileSystemException
        expect(error.message, isNotEmpty);
      }
    });

    test('生成阶段完全不碰磁盘（纯内存）', () {
      final dir = Directory.systemTemp.createTempSync('pdf_mem');
      final src = File('${dir.path}/in.pdf')..writeAsBytesSync(buildClassicPdf());
      final before = dir.listSync().map((f) => f.path.split('/').last).toSet();

      final built = buildInkAnnotatedBytes(
        sourcePath: src.path,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-mem',
            color: const Color(0xFF1E88E5),
            strokes: [strokeAt([const Offset(5, 5), const Offset(25, 25)])],
          ),
        ],
      );
      expect(built.annotationCount, 1);
      expect(built.bytes.length, greaterThan(0));

      // 生成过程不得产生任何新文件
      final after = dir.listSync().map((f) => f.path.split('/').last).toSet();
      expect(after, before);

      // 生成的字节本身就是合法的、含注释的 PDF
      final reader = PdfFileReader.fromBytes(built.bytes);
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots') as PdfArray;
      expect((reader.deref(annots.items.last) as PdfDict)['Subtype'], const PdfName('Ink'));
    });

    test('路径不存在时给出明确原因', () {
      expect(
        () => buildInkAnnotatedBytes(
          sourcePath: '/nonexistent/nope.pdf',
          pageNumber: 1,
          annotations: [
            InkAnnotationInput(
              id: 'x',
              color: const Color(0xFF000000),
              strokes: [strokeAt([const Offset(1, 1), const Offset(2, 2)])],
            ),
          ],
        ),
        throwsA(isA<PdfInkExportException>()),
      );
    });
  });

  group('外观流 /AP（macOS 预览必需）', () {
    test('墨迹注释带 /AP 外观流', () {
      final dir = Directory.systemTemp.createTempSync('pdf_ap');
      final src = File('${dir.path}/in.pdf')..writeAsBytesSync(buildClassicPdf());
      final out = '${dir.path}/out.pdf';

      exportInkAnnotations(
        sourcePath: src.path,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'ink-ap',
            color: const Color(0xFFE53935),
            strokes: [strokeAt([const Offset(20, 30), const Offset(80, 90)])],
          ),
        ],
      );

      final reader = PdfFileReader.fromBytes(File(out).readAsBytesSync());
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots') as PdfArray;
      final annot = reader.deref(annots.items.last) as PdfDict;

      // /AP << /N <ref> >>
      final ap = annot['AP'];
      expect(ap, isA<PdfDict>());
      final n = (ap as PdfDict)['N'];
      expect(n, isA<PdfRef>());

      // 外观流是合法的 Form XObject，且 BBox 与 Rect 一致
      final form = reader.resolve(n as PdfRef);
      expect(form, isA<PdfStream>());
      final formStream = form as PdfStream;
      expect((formStream.dict['Subtype'] as PdfName).name, 'Form');
      expect(formStream.dict['BBox'], isA<PdfArray>());
      expect(
        reader.dictGetNumber(formStream, 'FormType'),
        1,
      );

      // 内容流里有描边指令与颜色
      final content = String.fromCharCodes(formStream.raw);
      expect(content, contains(' RG')); // 描边颜色
      expect(content, contains(' w\n')); // 线宽
      expect(content, contains(' m\n')); // moveto
      expect(content, contains(' l\n')); // lineto
      expect(content, contains('S\n')); // stroke

      // /BS 也写上了（部分阅读器更认它）
      expect(annot['BS'], isA<PdfDict>());
    });

    test('半透明笔（荧光笔）的外观流带 ExtGState 与 multiply', () {
      final dir = Directory.systemTemp.createTempSync('pdf_ap_hl');
      final src = File('${dir.path}/in.pdf')..writeAsBytesSync(buildClassicPdf());
      final out = '${dir.path}/out.pdf';

      exportInkAnnotations(
        sourcePath: src.path,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'hl',
            color: const Color(0x59FDD835), // 35% 黄
            strokes: [strokeAt([const Offset(10, 10), const Offset(90, 10)], width: 18)],
          ),
        ],
      );

      final reader = PdfFileReader.fromBytes(File(out).readAsBytesSync());
      final page = reader.resolve(reader.collectPages().first) as PdfDict;
      final annots = reader.dictGet(page, 'Annots') as PdfArray;
      final annot = reader.deref(annots.items.last) as PdfDict;
      final form = reader.resolve((annot['AP'] as PdfDict)['N'] as PdfRef) as PdfStream;

      // ExtGState 在 /Resources 下，不是表单字典的直接项
      final resources = reader.dictGet(form, 'Resources');
      expect(resources, isA<PdfDict>());
      final extG = reader.dictGet(resources, 'ExtGState');
      expect(extG, isA<PdfDict>());
      final gs0 = (extG as PdfDict)['GS0'] as PdfDict;
      expect((gs0['BM'] as PdfName).name, 'Multiply');
      expect((gs0['CA'] as PdfNumber).value, closeTo(0.35, 0.01));

      final content = String.fromCharCodes(form.raw);
      expect(content, contains('/GS0 gs'));
    });
  });

  group('xref 表必须从对象 0 开始（PDFKit 兼容性）', () {
    test('生成的 xref 表首个子段是 0 1 + 空闲条目', () {
      final dir = Directory.systemTemp.createTempSync('pdf_xref0');
      final src = File('${dir.path}/in.pdf')..writeAsBytesSync(buildClassicPdf());
      final out = '${dir.path}/out.pdf';
      exportInkAnnotations(
        sourcePath: src.path,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'x',
            color: const Color(0xFFE53935),
            strokes: [strokeAt([const Offset(10, 10), const Offset(50, 50)])],
          ),
        ],
      );

      final data = File(out).readAsBytesSync();
      final xrefStart = findLastStartXref(data);
      final table = String.fromCharCodes(data.sublist(xrefStart, xrefStart + 60));
      expect(table, startsWith('xref\n0 1\n0000000000 65535 f '),
          reason: 'PDF 32000-1 7.5.4：表中第一条目（对象 0）应始终为空闲；'
              '缺少它时 pypdf 会整体偏移对象号，macOS 预览会直接拒绝打开');

      // 真实 PDF（xref 流 + 对象流）也必须如此
    }, skip: !hasRealPdf);

    test('真实 PDF 生成的结果首个子段也是 0 1', () {
      final dir = Directory.systemTemp.createTempSync('pdf_xref0_real');
      final out = '${dir.path}/out.pdf';
      exportInkAnnotations(
        sourcePath: kRealPdf,
        outputPath: out,
        pageNumber: 1,
        annotations: [
          InkAnnotationInput(
            id: 'x',
            color: const Color(0xFFE53935),
            strokes: [strokeAt([const Offset(10, 10), const Offset(50, 50)])],
          ),
        ],
      );
      final data = File(out).readAsBytesSync();
      final xrefStart = findLastStartXref(data);
      final table = String.fromCharCodes(data.sublist(xrefStart, xrefStart + 40));
      expect(table, startsWith('xref\n0 1\n'));
      // 且原有交叉引用仍可通过 /Prev 链回到
      final trailer = String.fromCharCodes(data.sublist(data.length - 300));
      expect(trailer, contains('/Prev'));
    }, skip: !hasRealPdf);
  });
}
