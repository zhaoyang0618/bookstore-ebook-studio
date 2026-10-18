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
  PdfFileReader._(this.data, this.entries, this.trailer);

  /// 解析整个文件。
  factory PdfFileReader.fromBytes(Uint8List data) {
    final startXref = findLastStartXref(data);
    final entries = <int, XrefEntry>{};
    final trailer = <String, PdfObject>{};

    // 沿 /Prev 链把所有交叉引用段收集起来。
    // 先遇到的（更新的）优先，所以用 putIfAbsent 语义。
    var offset = startXref;
    final visited = <int>{};
    while (offset >= 0 && offset < data.length && visited.add(offset)) {
      final section = _readXrefSection(data, offset);
      if (section == null) break;
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
    return PdfFileReader._(data, entries, trailer);
  }

  /// 从文件读取。
  factory PdfFileReader.fromFile(String path) =>
      PdfFileReader.fromBytes(File(path).readAsBytesSync());

  final Uint8List data;

  /// 对象号 → 交叉引用条目。
  final Map<int, XrefEntry> entries;

  /// 合并后的 trailer。
  final Map<String, PdfObject> trailer;

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

    return _XrefSection(entries, Map<String, PdfObject>.from(stream.dict.entries));
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
  _XrefSection(this.entries, this.trailer);
  final Map<int, XrefEntry> entries;
  final Map<String, PdfObject> trailer;
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

  /// 写完交叉引用与 trailer，返回完整文件字节。
  ///
  /// [previousStartXref] 是原文件的 `startxref` 值，作为新 trailer 的 `/Prev`。
  Uint8List finish(int previousStartXref) {
    final startXref = _currentLength;

    // 经典 xref 表：条目必须按对象号升序，每条固定 20 字节。
    final numbers = _updatedOffsets.keys.toList()..sort();
    final out = StringBuffer();
    out.write('xref\n');
    // 分段输出（连续的对象号合并成一段）
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
        final offset = _updatedOffsets[n]!;
        out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
      }
      i += 1;
    }

    final newSize = (_nextObjectNumber > reader.size ? _nextObjectNumber : reader.size);
    final rootRef = reader.root;
    out.write('trailer\n');
    final trailer = <String, PdfObject>{
      'Size': PdfNumber(newSize),
      'Root': rootRef,
      if (reader.trailer['Info'] != null) 'Info': reader.trailer['Info']!,
      if (reader.trailer['ID'] != null) 'ID': reader.trailer['ID']!,
      'Prev': PdfNumber(previousStartXref),
    };
    out.write(encodePdfObject(PdfDict(trailer)));
    out.write('\nstartxref\n$startXref\n%%EOF\n');

    _buffer.add(utf8.encode(out.toString()));
    return _buffer.toBytes();
  }
}
