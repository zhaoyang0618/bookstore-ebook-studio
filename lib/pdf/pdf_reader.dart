/// PDF 读取与增量写入（设计文档 3.3）。
///
/// 支持范围（覆盖现代 PDF 的两个难点）：
/// - **交叉引用**：经典 `xref` 表 与 PDF 1.5+ 的 xref **流**（含 PNG predictor）
/// - **对象流** `/ObjStm`：页面、目录等对象常被压缩在里面
///
/// 写入采用**增量更新**：只在文件尾追加新对象 + 新 xref + 新 trailer
///（用 `/Prev` 指向原交叉引用），不重写原内容。
/// 这是 PDF 规范明确支持的更新方式，风险最小。
///
/// @module ebook-studio/pdf/pdf_reader
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pdf_syntax.dart';

/// 交叉引用条目。
class XrefEntry {
  const XrefEntry(this.type, this.field1, this.field2);

  /// 0 = 空闲，1 = 普通对象（field1 为字节偏移），2 = 压缩对象
  /// （field1 为对象流号，field2 为流内索引）。
  final int type;
  final int field1;
  final int field2;
}

/// 一个 PDF 文件的读取器。
class PdfFileReader {
  PdfFileReader._(this.data, this.entries, this.trailer, this.lastSectionIsStream);

  /// 解析整个文件。
  factory PdfFileReader.fromBytes(Uint8List data) {
    // 头部校验：不是 PDF 时给出明确原因，而不是让后续解析产生
    // 一堆看不懂的偏移错误。
    if (data.length < 8 || data[0] != 0x25 || data[1] != 0x50 ||
        data[2] != 0x44 || data[3] != 0x46) {
      throw PdfSyntaxException('不是 PDF 文件（缺少 %PDF- 文件头）');
    }
    final startXref = findLastStartXref(data);
    final entries = <int, XrefEntry>{};
    final trailer = <String, PdfObject>{};

    // 沿 /Prev 链把所有交叉引用段收集起来。
    // 先遇到的（更新的）优先，所以用 putIfAbsent 语义。
    var offset = startXref;
    final visited = <int>{};
    var lastIsStream = false;
    var first = true;
    while (offset >= 0 && offset < data.length && visited.add(offset)) {
      final section = _readXrefSection(data, offset);
      if (section == null) break;
      if (first) {
        lastIsStream = section.isStream;
        first = false;
      }
      section.entries.forEach((number, entry) {
        entries.putIfAbsent(number, () => entry);
      });
      trailer.addAll(section.trailer); // 更旧的段不覆盖已有的键
      final prev = section.trailer['Prev'];
      offset = prev is PdfNumber ? prev.value.toInt() : -1;
    }

    if (trailer['Root'] == null) {
      throw PdfSyntaxException('trailer 里找不到 /Root');
    }
    return PdfFileReader._(data, entries, trailer, lastIsStream);
  }

  /// 从文件读取。
  factory PdfFileReader.fromFile(String path) =>
      PdfFileReader.fromBytes(File(path).readAsBytesSync());

  final Uint8List data;

  /// 对象号 → 交叉引用条目。
  final Map<int, XrefEntry> entries;

  /// 合并后的 trailer。
  final Map<String, PdfObject> trailer;

  /// 最后一段交叉引用是**流**（PDF 1.5+）还是经典表。
  ///
  /// 增量更新必须沿用同一种风格：CoreGraphics（macOS 预览的引擎）
  /// 不接受「经典表 + /Prev 指向 xref 流」这种混用，
  /// 会报 `failed to find start of cross-reference section`。
  final bool lastSectionIsStream;

  final Map<int, PdfObject> _objectCache = {};
  final Map<int, ({Uint8List raw, int first, List<int> offsets})> _objStmCache = {};

  /// `/Root` 引用（文档目录）。
  PdfRef get root => trailer['Root']! as PdfRef;

  /// `/Size`：对象号上界（下一个可用对象号）。
  int get size {
    final value = trailer['Size'];
    if (value is PdfNumber) return value.value.toInt();
    if (entries.isEmpty) return 1;
    return entries.keys.reduce((a, b) => a > b ? a : b) + 1;
  }

  /// 读取对象（自动解对象流）。不存在返回 null。
  PdfObject? resolve(PdfRef ref) {
    final cached = _objectCache[ref.number];
    if (cached != null) return cached;
    final entry = entries[ref.number];
    if (entry == null) return null;

    PdfObject? object;
    if (entry.type == 1) {
      object = _readIndirectAt(entry.field1)?.object;
    } else if (entry.type == 2) {
      object = _readFromObjectStream(entry.field1, entry.field2);
    }
    if (object != null) _objectCache[ref.number] = object;
    return object;
  }

  /// 读取直接对象（若不是引用则原样返回）。
  PdfObject? deref(PdfObject? object) => object is PdfRef ? resolve(object) : object;

  /// 取字典项并解引用。
  ///
  /// [object] 可以是字典、**指向字典的引用**（例如 trailer 的 `/Root`），
  /// 也可以是**流对象**（流的字典在 `PdfStream.dict` 里）——
  /// 内部统一归一化成字典，避免调用方到处写 `deref` 与类型判断。
  PdfObject? dictGet(PdfObject? object, String key) {
    final dict = _asDict(deref(object));
    if (dict == null) return null;
    return deref(dict[key]);
  }

  /// 把对象归一化成字典：字典本身，或流对象的字典。
  static PdfDict? _asDict(PdfObject? object) => switch (object) {
        PdfDict() => object,
        PdfStream(:final dict) => dict,
        _ => null,
      };

  /// 取数字项（可继承）。
  num? dictGetNumber(PdfObject? dict, String key) {
    final value = dictGet(dict, key);
    return value is PdfNumber ? value.value : null;
  }

  /// 取名字项。
  String? dictGetName(PdfObject? dict, String key) {
    final value = dictGet(dict, key);
    return value is PdfName ? value.name : null;
  }

  /// 取数组项。
  List<PdfObject>? dictGetArray(PdfObject? dict, String key) {
    final value = dictGet(dict, key);
    return value is PdfArray ? value.items : null;
  }

  /// 页面总数。
  int get pageCount {
    final pagesRef = dictGet(root, 'Pages');
    final count = dictGetNumber(pagesRef, 'Count');
    if (count != null) return count.toInt();
    return collectPages().length;
  }

  /// 按顺序收集所有页面对象的引用。
  List<PdfRef> collectPages() {
    final result = <PdfRef>[];
    final pagesRef = dictGet(root, 'Pages');
    if (pagesRef is! PdfDict) return result;
    _walkPageTree(pagesRef, result, <int>{});
    return result;
  }

  void _walkPageTree(PdfDict node, List<PdfRef> out, Set<int> visiting) {
    final type = dictGetName(node, 'Type');
    final kids = dictGetArray(node, 'Kids');
    if (kids == null || (type == 'Page' && !node.entries.containsKey('Kids'))) {
      // 叶子：页面
      final number = _numberOf(node);
      if (number != null) out.add(PdfRef(number));
      return;
    }
    for (final kid in kids) {
      if (kid is! PdfRef) continue;
      if (!visiting.add(kid.number)) continue; // 防御环
      final child = resolve(kid);
      if (child is PdfDict) _walkPageTree(child, out, visiting);
    }
  }

  /// 把某页的 MediaBox 与 Rotate 从祖先继承下来。
  ({List<double> mediaBox, int rotate}) pageGeometry(PdfDict page) {
    var current = page;
    final visited = <int>{};
    for (var hop = 0; hop < 64; hop++) {
      final box = dictGetArray(current, 'MediaBox');
      final rotate = dictGetNumber(current, 'Rotate');
      if (box != null && box.length >= 4) {
        final values = box.whereType<PdfNumber>().map((n) => n.value.toDouble()).toList();
        if (values.length >= 4) {
          return (mediaBox: values, rotate: rotate?.toInt() ?? 0);
        }
      }
      final parent = dictGet(current, 'Parent');
      if (parent is! PdfDict) break;
      final number = _numberOf(parent);
      if (number != null && !visited.add(number)) break;
      current = parent;
    }
    // 兜底：A4
    return (mediaBox: const [0, 0, 595.28, 841.89], rotate: 0);
  }

  int? _numberOf(PdfObject object) {
    for (final entry in entries.keys) {
      if (identical(_objectCache[entry], object)) return entry;
    }
    return null;
  }

  // ---------- 内部分析 ----------

  ({int number, int generation, PdfObject object})? _readIndirectAt(int offset) {
    if (offset < 0 || offset >= data.length) return null;
    try {
      return PdfParser(data, offset).parseIndirectObject();
    } on PdfSyntaxException {
      return null;
    }
  }

  PdfObject? _readFromObjectStream(int streamNumber, int index) {
    final cached = _objStmCache[streamNumber];
    late final Uint8List raw;
    late final int first;
    late final List<int> offsets;

    if (cached != null) {
      raw = cached.raw;
      first = cached.first;
      offsets = cached.offsets;
    } else {
      final entry = entries[streamNumber];
      if (entry == null || entry.type != 1) return null;
      final indirect = _readIndirectAt(entry.field1);
      if (indirect == null) return null;
      final stream = indirect.object;
      if (stream is! PdfStream) return null;
      final decoded = decodeStream(stream);
      if (decoded == null) return null;
      final n = (stream.dict['N'] as PdfNumber?)?.value.toInt();
      final f = (stream.dict['First'] as PdfNumber?)?.value.toInt();
      if (n == null || f == null) return null;

      // 头部是 N 组「对象号 相对偏移」的**裸数字序列**（没有方括号！），
      // 形如 `1858 0 1859 62 ...`，终止于 /First 偏移。
      final headerParser = PdfParser(decoded);
      final offs = <int>[];
      while (headerParser.pos < f) {
        final before = headerParser.pos;
        PdfObject value;
        try {
          value = headerParser.parseObject();
        } on PdfSyntaxException {
          break;
        }
        if (value is! PdfNumber) break;
        offs.add(value.value.toInt());
        if (headerParser.pos == before) break; // 防死循环
      }
      if (offs.length < n * 2) return null;
      offs.removeRange(n * 2, offs.length);
      _objStmCache[streamNumber] =
          (raw: decoded, first: f, offsets: offs);
      raw = decoded;
      first = f;
      offsets = offs;
    }

    // offsets 是扁平的交错序列 [对象号0, 偏移0, 对象号1, 偏移1, ...]，
    // 第 index 个对象的偏移在下标 index*2 + 1 处。
    final pairCount = offsets.length ~/ 2;
    if (index < 0 || index >= pairCount) return null;
    final relative = offsets[index * 2 + 1];
    if (relative < 0) return null;
    final start = first + relative;
    if (start >= raw.length) return null;
    try {
      return PdfParser(raw, start).parseObject();
    } on PdfSyntaxException {
      return null;
    }
  }

  // ---------- 交叉引用 ----------

  static _XrefSection? _readXrefSection(Uint8List data, int offset) {
    if (offset < 0 || offset >= data.length) return null;
    final parser = PdfParser(data, offset);
    parser.skipWhitespace();
    final c = data.length > parser.pos ? data[parser.pos] : -1;

    if (c == 0x78) {
      // 经典表：以 'xref' 开头
      return _readClassicXref(data, offset);
    }
    // 否则是 xref 流
    return _readXrefStream(data, offset);
  }

  static _XrefSection? _readClassicXref(Uint8List data, int offset) {
    final parser = PdfParser(data, offset);
    parser.skipWhitespace();
    // 跳过 'xref'
    parser.pos += 4;
    final entries = <int, XrefEntry>{};
    while (true) {
      parser.skipWhitespace();
      if (parser.atEnd) break;
      final save = parser.pos;
      final token = _readToken(data, parser);
      if (token == 'trailer') {
        final dict = PdfParser(data, parser.pos).parseObject();
        if (dict is! PdfDict) return null;
        return _XrefSection(entries, dict.entries);
      }
      final start = int.tryParse(token);
      if (start == null) {
        parser.pos = save;
        break;
      }
      final count = int.tryParse(_readToken(data, parser));
      if (count == null) break;
      parser.skipWhitespace();
      for (var i = 0; i < count; i++) {
        // 每条固定 20 字节：nnnnnnnnnn ggggg n
        while (parser.pos < data.length &&
            (data[parser.pos] == 0x20 || data[parser.pos] == 0x0A || data[parser.pos] == 0x0D)) {
          parser.pos += 1;
        }
        final entryStart = parser.pos;
        final lineEnd = _lineEnd(data, entryStart);
        final line = String.fromCharCodes(data.sublist(entryStart, lineEnd)).trim();
        parser.pos = lineEnd;
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 3) {
          final objOffset = int.tryParse(parts[0]);
          // 第三列是标志字母：n = 使用中，f = 空闲（不是数字！）
          final flag = parts[2];
          if (objOffset != null) {
            entries[start + i] =
                flag == 'n' ? XrefEntry(1, objOffset, 0) : const XrefEntry(0, 0, 0);
          }
        }
      }
    }
    // 没读到 trailer：尝试在附近找
    final trailerIndex = _indexOfAscii(data, 'trailer', offset);
    if (trailerIndex > 0) {
      final dict = PdfParser(data, trailerIndex + 7).parseObject();
      if (dict is PdfDict) return _XrefSection(entries, dict.entries);
    }
    return null;
  }

  static _XrefSection? _readXrefStream(Uint8List data, int offset) {
    final parser = PdfParser(data, offset);
    // catch 里直接 return，所以这里用 final + 确定赋值
    final ({int number, int generation, PdfObject object}) indirect;
    try {
      indirect = parser.parseIndirectObject();
    } on PdfSyntaxException {
      return null;
    }
    final stream = indirect.object;
    if (stream is! PdfStream) return null;

    final wArray = stream.dict['W'];
    if (wArray is! PdfArray) return null;
    final widths = wArray.items.whereType<PdfNumber>().map((n) => n.value.toInt()).toList();
    if (widths.isEmpty) return null;

    final decoded = decodeStream(stream);
    if (decoded == null) return null;

    final entryWidth = widths.fold<int>(0, (sum, w) => sum + w);
    if (entryWidth <= 0) return null;

    // /Index 默认 [0 Size]
    var index = <int>[];
    final indexArray = stream.dict['Index'];
    if (indexArray is PdfArray) {
      index = indexArray.items.whereType<PdfNumber>().map((n) => n.value.toInt()).toList();
    } else {
      final size = (stream.dict['Size'] as PdfNumber?)?.value.toInt() ?? 0;
      index = [0, size];
    }

    final entries = <int, XrefEntry>{};
    var cursor = 0;
    for (var pair = 0; pair + 1 < index.length; pair += 2) {
      final start = index[pair];
      final count = index[pair + 1];
      for (var i = 0; i < count; i++) {
        if (cursor + entryWidth > decoded.length) break;
        final fields = <int>[];
        var p = cursor;
        for (final width in widths) {
          var value = 0;
          for (var k = 0; k < width; k++) {
            value = (value << 8) | decoded[p + k];
          }
          fields.add(value);
          p += width;
        }
        cursor += entryWidth;
        // 宽度为 0 的字段取默认值：type 默认 1，其余默认 0
        final type = widths[0] == 0 ? 1 : fields[0];
        final f1 = widths.length > 1 ? fields[1] : 0;
        final f2 = widths.length > 2 ? fields[2] : 0;
        entries[start + i] = XrefEntry(type, f1, f2);
      }
    }

    return _XrefSection(entries, Map<String, PdfObject>.from(stream.dict.entries), isStream: true);
  }

  static int _lineEnd(Uint8List data, int from) {
    var i = from;
    while (i < data.length && data[i] != 0x0A && data[i] != 0x0D) {
      i += 1;
    }
    return i;
  }

  static String _readToken(Uint8List data, PdfParser parser) {
    parser.skipWhitespace();
    final start = parser.pos;
    while (parser.pos < data.length) {
      final c = data[parser.pos];
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) break;
      parser.pos += 1;
    }
    return String.fromCharCodes(data.sublist(start, parser.pos));
  }

  static int _indexOfAscii(Uint8List data, String needle, int from) {
    final bytes = ascii.encode(needle);
    outer:
    for (var i = from; i <= data.length - bytes.length; i++) {
      for (var k = 0; k < bytes.length; k++) {
        if (data[i + k] != bytes[k]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

class _XrefSection {
  _XrefSection(this.entries, this.trailer, {this.isStream = false});
  final Map<int, XrefEntry> entries;
  final Map<String, PdfObject> trailer;
  final bool isStream;
}

/// 解压流的字节（支持 FlateDecode 与 PNG predictor）。
///
/// 只处理我们需要的两种：`/Filter /FlateDecode`（对象流、xref 流常用）
/// 与无过滤。其它过滤器返回 null，由调用方决定如何降级。
Uint8List? decodeStream(PdfStream stream) {
  final filter = stream.dict['Filter'];
  final filters = <String>[];
  if (filter is PdfName) {
    filters.add(filter.name);
  } else if (filter is PdfArray) {
    for (final item in filter.items) {
      if (item is PdfName) filters.add(item.name);
    }
  }

  var bytes = stream.raw;
  if (filters.isEmpty) return bytes;
  if (filters.length != 1 || filters.first != 'FlateDecode') return null;

  try {
    bytes = Uint8List.fromList(ZLibDecoder(raw: false).convert(bytes));
  } catch (_) {
    try {
      bytes = Uint8List.fromList(ZLibDecoder(raw: true).convert(bytes));
    } catch (_) {
      return null;
    }
  }

  // PNG predictor：xref 流常用
  final params = stream.dict['DecodeParms'];
  if (params is PdfDict) {
    final predictor = (params['Predictor'] as PdfNumber?)?.value.toInt() ?? 1;
    if (predictor >= 10) {
      final colors = (params['Colors'] as PdfNumber?)?.value.toInt() ?? 1;
      final bpc = (params['BitsPerComponent'] as PdfNumber?)?.value.toInt() ?? 8;
      final columns = (params['Columns'] as PdfNumber?)?.value.toInt() ?? 1;
      bytes = _undoPngPredictor(bytes, colors, bpc, columns);
    }
  }
  return bytes;
}

/// 还原 PNG 预测器（PDF 规范 7.4.4.4）。
Uint8List _undoPngPredictor(Uint8List data, int colors, int bitsPerComponent, int columns) {
  final bytesPerPixel = (colors * bitsPerComponent + 7) ~/ 8;
  final rowLength = (columns * colors * bitsPerComponent + 7) ~/ 8;
  final rowCount = data.length ~/ (rowLength + 1);
  final out = Uint8List(rowCount * rowLength);
  var prevRow = Uint8List(rowLength);

  for (var row = 0; row < rowCount; row++) {
    final tag = data[row * (rowLength + 1)];
    final src = row * (rowLength + 1) + 1;
    final current = Uint8List(rowLength);
    for (var i = 0; i < rowLength; i++) {
      final raw = data[src + i];
      final left = i >= bytesPerPixel ? current[i - bytesPerPixel] : 0;
      final up = prevRow[i];
      final upLeft = i >= bytesPerPixel ? prevRow[i - bytesPerPixel] : 0;
      current[i] = switch (tag) {
        0 => raw,
        1 => (raw + left) & 0xFF,
        2 => (raw + up) & 0xFF,
        3 => (raw + ((left + up) >> 1)) & 0xFF,
        4 => (raw + _paeth(left, up, upLeft)) & 0xFF,
        _ => raw,
      };
    }
    out.setRange(row * rowLength, (row + 1) * rowLength, current);
    prevRow = current;
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// 增量写入器：在文件尾追加对象与新的交叉引用。
class PdfIncrementalWriter {
  PdfIncrementalWriter(this.reader)
      : _nextObjectNumber = reader.size,
        _buffer = BytesBuilder(copy: false)..add(reader.data);

  final PdfFileReader reader;
  final BytesBuilder _buffer;
  int _nextObjectNumber;

  /// 本次更新涉及的对象号 → 在输出文件中的字节偏移。
  final Map<int, int> _updatedOffsets = {};

  /// 分配一个新的对象号。
  int allocate() => _nextObjectNumber++;

  int get _currentLength => _buffer.length;

  /// 追加一个顶层对象（非流）。
  int addObject(PdfObject object) {
    final number = allocate();
    _appendIndirect(number, object);
    return number;
  }

  /// 以指定对象号写入（覆盖旧版本，用于更新页面 / 注释数组）。
  void replaceObject(int number, PdfObject object) {
    _appendIndirect(number, object);
  }

  /// 追加一个流对象。
  int addStream(PdfDict dict, List<int> content) {
    final number = allocate();
    final withLength = PdfDict(Map.of(dict.entries))
      ..['Length'] = PdfNumber(content.length);
    final header = '$number 0 obj\n${withLength.encode()}\nstream\n';
    _updatedOffsets[number] = _currentLength;
    _buffer.add(utf8.encode(header));
    _buffer.add(content);
    _buffer.add(utf8.encode('\nendstream\nendobj\n'));
    return number;
  }

  void _appendIndirect(int number, PdfObject object) {
    _updatedOffsets[number] = _currentLength;
    _buffer.add(utf8.encode('$number 0 obj\n${encodePdfObject(object)}\nendobj\n'));
  }

  /// 写完交叉引用并返回完整文件字节。
  ///
  /// [previousStartXref] 是原文件的 `startxref` 值，作为 `/Prev`。
  ///
  /// **风格必须与原文件一致**：原文件用 xref 流（PDF 1.5+）就继续用流，
  /// 用经典表就继续用表。混用会让 CoreGraphics（macOS 预览的引擎）
  /// 直接报 `failed to find start of cross-reference section` 并拒绝打开文件。
  Uint8List finish(int previousStartXref) =>
      reader.lastSectionIsStream
          ? _finishWithXrefStream(previousStartXref)
          : _finishWithClassicTable(previousStartXref);

  /// 经典交叉引用表（PDF 1.4 及更早的风格）。
  Uint8List _finishWithClassicTable(int previousStartXref) {
    final startXref = _currentLength;

    // 条目必须按对象号升序，每条固定 20 字节。
    final numbers = _updatedOffsets.keys.where((n) => n > 0).toList()..sort();
    final out = StringBuffer();
    out.write('xref\n');

    // PDF 32000-1 7.5.4：表的第一个子段必须是对象 0 的空闲条目。
    // 缺少它时 pypdf 会整体偏移对象号，PDFKit 会拒绝打开。
    out.write('0 1\n');
    out.write('0000000000 65535 f \n');

    var i = 0;
    while (i < numbers.length) {
      final start = numbers[i];
      var end = start;
      while (i + 1 < numbers.length && numbers[i + 1] == end + 1) {
        i += 1;
        end = numbers[i];
      }
      final count = end - start + 1;
      out.write('$start $count\n');
      for (var n = start; n <= end; n++) {
        // 每行必须正好 20 字节：10 位偏移 + 空格 + 5 位代次 + 空格 + 标志 + 空格 + 换行
        out.write('${_updatedOffsets[n]!.toString().padLeft(10, '0')} 00000 n \n');
      }
      i += 1;
    }

    out.write('trailer\n');
    out.write(encodePdfObject(PdfDict(_trailerEntries(previousStartXref))));
    out.write('\nstartxref\n$startXref\n%%EOF\n');

    _buffer.add(utf8.encode(out.toString()));
    return _buffer.toBytes();
  }

  /// 交叉引用流（PDF 1.5+ 的风格）。
  ///
  /// 写一份**完整**的条目表（覆盖 0..Size-1 的所有对象），
  /// 因此即使原文件的 xref 段读取有问题也能正确解析；
  /// 同时保留 `/Prev` 指向原段，作为额外的回退路径。
  Uint8List _finishWithXrefStream(int previousStartXref) {
    // 先确定 xref 流自己的对象号与偏移：它必须**出现在自己写的表里**，
    // 否则严格解析器（qpdf / CoreGraphics）会认为该对象是空闲的，
    // 进而报 `unable to find /Root dictionary` 或直接拒绝打开文件。
    final xrefNumber = allocate();
    final xrefOffset = _currentLength;
    final newSize = _nextObjectNumber > reader.size ? _nextObjectNumber : reader.size;

    // 条目：type(1 字节) + field2(4 字节) + field3(2 字节)
    final entries = BytesBuilder();
    void entry(int type, int f1, int f2) {
      entries.addByte(type & 0xFF);
      entries.add([(f1 >> 24) & 0xFF, (f1 >> 16) & 0xFF, (f1 >> 8) & 0xFF, f1 & 0xFF]);
      entries.add([(f2 >> 8) & 0xFF, f2 & 0xFF]);
    }

    for (var n = 0; n < newSize; n++) {
      if (n == 0) {
        entry(0, 0, 65535); // 0 号对象恒为空闲（PDF 32000-1 7.5.4）
        continue;
      }
      if (n == xrefNumber) {
        entry(1, xrefOffset, 0); // 交叉引用流自身
        continue;
      }
      final mine = _updatedOffsets[n];
      if (mine != null) {
        entry(1, mine, 0);
        continue;
      }
      final original = reader.entries[n];
      if (original != null) {
        entry(original.type, original.field1, original.field2);
        continue;
      }
      entry(0, 0, 0); // 未使用
    }

    final compressed = Uint8List.fromList(ZLibEncoder().convert(entries.toBytes()));

    final dict = PdfDict({
      'Type': const PdfName('XRef'),
      'Size': PdfNumber(newSize),
      'W': PdfArray([const PdfNumber(1), const PdfNumber(4), const PdfNumber(2)]),
      ..._trailerEntries(previousStartXref),
      'Filter': const PdfName('FlateDecode'),
      'Length': PdfNumber(compressed.length),
    });

    _buffer.add(utf8.encode('$xrefNumber 0 obj\n${dict.encode()}\nstream\n'));
    _buffer.add(compressed);
    _buffer.add(utf8.encode('\nendstream\nendobj\n'));
    _buffer.add(utf8.encode('startxref\n$xrefOffset\n%%EOF\n'));
    return _buffer.toBytes();
  }

  /// trailer / xref 流字典里共用的条目。
  Map<String, PdfObject> _trailerEntries(int previousStartXref) => {
        'Size': PdfNumber(_nextObjectNumber > reader.size ? _nextObjectNumber : reader.size),
        'Root': reader.root,
        if (reader.trailer['Info'] != null) 'Info': reader.trailer['Info']!,
        if (reader.trailer['ID'] != null) 'ID': reader.trailer['ID']!,
        'Prev': PdfNumber(previousStartXref),
      };
}
