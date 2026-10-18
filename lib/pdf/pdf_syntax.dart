/// PDF 对象模型与语法分析（设计文档 3.3：原生 PDF 注释写入的基础）。
///
/// ## 为什么自己写
///
/// 要把手写墨迹写成 **原生 `/Ink` 注释**（让 dsh 版 PDF.js、Acrobat 都能看到），
/// 需要在 PDF 里追加对象。可行方案对比：
///
/// | 方案 | 结论 |
/// |---|---|
/// | pdfrx 的 PDFium 绑定 | `FPDFAnnot_*` 是内部私有 API，且没有 `FPDF_Save*`，用不了 |
/// | syncfusion_flutter_pdf | 有 `PdfDictionary` 等低层对象，但**没有墨迹注释类型**，且是商业许可 |
/// | 调用 mylibrary 的 TS 实现 | 需要用户装 Node，违背「软件不装外部工具」 |
/// | **自己写增量更新** | 纯 Dart、无新依赖、可本地完整测试 ← 选它 |
///
/// ## 只做「增量追加」
///
/// 不重写整个 PDF，只在文件尾部追加：
/// 1. 新对象（注释、更新后的页面 / `/Annots`）
/// 2. 新的交叉引用表（经典 `xref` 表即可，与原有的 xref 流混用是合法的）
/// 3. 新的 trailer，用 `/Prev` 指向原来的交叉引用位置
///
/// 阅读器会从文件尾往 `Prev` 链上游走，因此看到的是更新后的版本。
/// 这样就不必理解原文件的全部结构 —— 但**必须能读取对象**，
/// 所以仍需要解析 xref（表与流两种）、对象流、以及页面树。
///
/// @module ebook-studio/pdf/pdf_syntax
library;

import 'dart:convert';
import 'dart:typed_data';

// ---------- 对象模型 ----------

/// PDF 对象。
sealed class PdfObject {
  const PdfObject();
}

/// `null`
class PdfNull extends PdfObject {
  const PdfNull();
}

/// `true` / `false`
class PdfBool extends PdfObject {
  const PdfBool(this.value);
  final bool value;
}

/// 整数或实数
class PdfNumber extends PdfObject {
  const PdfNumber(this.value);
  final num value;

  /// 序列化：整数不带小数点，小数最多保留 4 位（足够表示点坐标）。
  String encode() {
    if (value is int || value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  @override
  String toString() => 'PdfNumber($value)';
}

/// `/Name`
class PdfName extends PdfObject {
  const PdfName(this.name);
  final String name;

  /// 编码为 PDF 名字，非 ASCII 与分隔符用 `#xx` 转义。
  String encode() {
    final buffer = StringBuffer('/');
    for (final byte in utf8.encode(name)) {
      final isRegular = byte > 0x20 &&
          byte < 0x7F &&
          !_nameDelimiters.contains(byte);
      if (isRegular) {
        buffer.writeCharCode(byte);
      } else {
        buffer.write('#${byte.toRadixString(16).padLeft(2, '0')}');
      }
    }
    return buffer.toString();
  }

  static const Set<int> _nameDelimiters = {
    0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25, 0x23,
  };

  @override
  String toString() => 'PdfName($name)';
}

/// `(literal)` 或 `<hex>` 字符串。
///
/// 保留原始字节：PDF 字符串既可能是 PDFDocEncoding，也可能是
/// UTF-16BE（写中文必须用后者）。这里不做自动解码，避免瞎猜编码。
class PdfString extends PdfObject {
  const PdfString(this.bytes, {this.isHex = false});
  final Uint8List bytes;
  final bool isHex;

  /// 由 UTF-16BE 构造（写中文用）。
  ///
  /// PDF 普通字符串的 PDFDocEncoding 装不下中文，必须用 hex 串
  /// 加 BOM `FEFF` —— 这是 TS 侧踩过的坑。
  factory PdfString.utf16(String text) {
    final units = <int>[0xFE, 0xFF];
    for (final unit in text.codeUnits) {
      units.add((unit >> 8) & 0xFF);
      units.add(unit & 0xFF);
    }
    return PdfString(Uint8List.fromList(units), isHex: true);
  }

  String encode() {
    if (isHex) {
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return '<$hex>';
    }
    final buffer = StringBuffer('(');
    for (final byte in bytes) {
      if (byte == 0x28 || byte == 0x29 || byte == 0x5C) {
        buffer.write('\\${String.fromCharCode(byte)}');
      } else if (byte < 0x20 || byte > 0x7E) {
        buffer.write('\\${byte.toRadixString(8).padLeft(3, '0')}');
      } else {
        buffer.writeCharCode(byte);
      }
    }
    buffer.write(')');
    return buffer.toString();
  }

  @override
  String toString() => 'PdfString(${bytes.length} bytes, hex: $isHex)';
}

/// 间接引用 `N G R`
class PdfRef extends PdfObject {
  const PdfRef(this.number, [this.generation = 0]);
  final int number;
  final int generation;

  String encode() => '$number $generation R';

  @override
  String toString() => 'PdfRef($number $generation)';

  @override
  bool operator ==(Object other) =>
      other is PdfRef && other.number == number && other.generation == generation;

  @override
  int get hashCode => Object.hash(number, generation);
}

/// 数组 `[...]`
class PdfArray extends PdfObject {
  PdfArray([List<PdfObject>? items]) : items = items ?? <PdfObject>[];
  final List<PdfObject> items;

  String encode() => '[${items.map(encodePdfObject).join(' ')}]';

  @override
  String toString() => 'PdfArray(${items.length})';
}

/// 字典 `<<...>>`
class PdfDict extends PdfObject {
  PdfDict([Map<String, PdfObject>? entries]) : entries = entries ?? <String, PdfObject>{};
  final Map<String, PdfObject> entries;

  PdfObject? operator [](String key) => entries[key];
  void operator []=(String key, PdfObject value) => entries[key] = value;

  String encode() {
    final buffer = StringBuffer('<<');
    entries.forEach((key, value) {
      buffer.write(PdfName(key).encode());
      buffer.write(' ');
      buffer.write(encodePdfObject(value));
      buffer.write(' ');
    });
    buffer.write('>>');
    return buffer.toString();
  }

  @override
  String toString() => 'PdfDict(${entries.keys.join(', ')})';
}

/// 流对象：字典 + 原始字节。
///
/// 只保留**原始（未解码）**字节，解码按需进行 —— 我们只需读
/// 对象流与交叉引用流，不必把所有流都解开。
class PdfStream extends PdfObject {
  PdfStream(this.dict, this.raw);
  final PdfDict dict;
  final Uint8List raw;

  @override
  String toString() => 'PdfStream(${raw.length} bytes, ${dict.entries.length} keys)';
}

/// 序列化任意对象为 PDF 语法。
String encodePdfObject(PdfObject object) => switch (object) {
      PdfNull() => 'null',
      PdfBool(:final value) => value ? 'true' : 'false',
      PdfNumber() => object.encode(),
      PdfName() => object.encode(),
      PdfString() => object.encode(),
      PdfRef() => object.encode(),
      PdfArray() => object.encode(),
      PdfDict() => object.encode(),
      PdfStream() => object.dict.encode(),
    };

// ---------- 词法 / 语法分析 ----------

/// PDF 语法解析异常。
class PdfSyntaxException implements Exception {
  PdfSyntaxException(this.message, [this.offset]);
  final String message;
  final int? offset;
  @override
  String toString() => 'PdfSyntaxException: $message${offset == null ? '' : ' (偏移 $offset)'}';
}

/// 解析器：从字节缓冲区读取 PDF 对象。
///
/// 面向 PDF 1.7 的对象语法，支持注释、转义字符串、`#xx` 名字转义。
class PdfParser {
  PdfParser(this.data, [this.pos = 0]);

  final Uint8List data;
  int pos;

  bool get atEnd => pos >= data.length;

  int _peek([int ahead = 0]) => pos + ahead < data.length ? data[pos + ahead] : -1;

  bool _isWhitespace(int c) =>
      c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

  bool _isDelimiter(int c) =>
      c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B ||
      c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25;

  /// 跳过空白与 `%` 注释。
  void skipWhitespace() {
    while (!atEnd) {
      final c = _peek();
      if (_isWhitespace(c)) {
        pos += 1;
      } else if (c == 0x25) {
        while (!atEnd && _peek() != 0x0A && _peek() != 0x0D) {
          pos += 1;
        }
      } else {
        break;
      }
    }
  }

  /// 读取一个对象。
  PdfObject parseObject() {
    skipWhitespace();
    if (atEnd) throw PdfSyntaxException('意外到达文件末尾', pos);
    final c = _peek();

    if (c == 0x2F) return _parseName();
    if (c == 0x28) return _parseLiteralString();
    if (c == 0x5B) return _parseArray();
    if (c == 0x3C) {
      if (_peek(1) == 0x3C) return _parseDict();
      return _parseHexString();
    }
    if (c == 0x5D || c == 0x3E) throw PdfSyntaxException('意外的分隔符', pos);
    return _parseKeywordOrNumber();
  }

  PdfName _parseName() {
    pos += 1; // '/'
    final bytes = <int>[];
    while (!atEnd) {
      final c = _peek();
      if (_isWhitespace(c) || _isDelimiter(c)) break;
      if (c == 0x23 && _peek(1) != -1 && _peek(2) != -1) {
        // #xx 转义
        final hex = String.fromCharCodes([_peek(1), _peek(2)]);
        final value = int.tryParse(hex, radix: 16);
        if (value != null) {
          bytes.add(value);
          pos += 3;
          continue;
        }
      }
      bytes.add(c);
      pos += 1;
    }
    return PdfName(utf8.decode(bytes, allowMalformed: true));
  }

  PdfString _parseLiteralString() {
    pos += 1; // '('
    final bytes = <int>[];
    var depth = 1;
    while (!atEnd) {
      final c = _peek();
      pos += 1;
      if (c == 0x5C) {
        // 转义
        final e = _peek();
        pos += 1;
        switch (e) {
          case 0x6E:
            bytes.add(0x0A);
          case 0x72:
            bytes.add(0x0D);
          case 0x74:
            bytes.add(0x09);
          case 0x62:
            bytes.add(0x08);
          case 0x66:
            bytes.add(0x0C);
          case 0x28:
          case 0x29:
          case 0x5C:
            bytes.add(e);
          case 0x0A:
            break; // 续行
          case 0x0D:
            if (_peek() == 0x0A) pos += 1;
          default:
            if (e >= 0x30 && e <= 0x37) {
              // 八进制，最多 3 位
              var value = e - 0x30;
              for (var k = 0; k < 2; k++) {
                final n = _peek();
                if (n >= 0x30 && n <= 0x37) {
                  value = value * 8 + (n - 0x30);
                  pos += 1;
                } else {
                  break;
                }
              }
              bytes.add(value & 0xFF);
            } else {
              bytes.add(e);
            }
        }
        continue;
      }
      if (c == 0x28) {
        depth += 1;
      } else if (c == 0x29) {
        depth -= 1;
        if (depth == 0) break;
      }
      bytes.add(c);
    }
    return PdfString(Uint8List.fromList(bytes));
  }

  PdfString _parseHexString() {
    pos += 1; // '<'
    final digits = <int>[];
    while (!atEnd && _peek() != 0x3E) {
      final c = _peek();
      pos += 1;
      if (_isWhitespace(c)) continue;
      digits.add(c);
    }
    if (!atEnd) pos += 1; // '>'
    if (digits.length.isOdd) digits.add(0x30); // 补 0
    final bytes = <int>[];
    for (var i = 0; i < digits.length; i += 2) {
      final value = int.tryParse(String.fromCharCodes([digits[i], digits[i + 1]]), radix: 16);
      bytes.add(value ?? 0);
    }
    return PdfString(Uint8List.fromList(bytes), isHex: true);
  }

  PdfArray _parseArray() {
    pos += 1; // '['
    final items = <PdfObject>[];
    while (true) {
      skipWhitespace();
      if (atEnd) throw PdfSyntaxException('数组未闭合', pos);
      if (_peek() == 0x5D) {
        pos += 1;
        break;
      }
      items.add(parseObject());
    }
    return PdfArray(items);
  }

  PdfDict _parseDict() {
    pos += 2; // '<<'
    final dict = PdfDict();
    while (true) {
      skipWhitespace();
      if (atEnd) throw PdfSyntaxException('字典未闭合', pos);
      if (_peek() == 0x3E && _peek(1) == 0x3E) {
        pos += 2;
        break;
      }
      if (_peek() != 0x2F) throw PdfSyntaxException('字典的键必须是名字', pos);
      final key = _parseName().name;
      final value = parseObject();
      dict[key] = value;
    }
    return dict;
  }

  /// 关键字（true/false/null）、数字，或「数字 数字 R」形式的引用。
  PdfObject _parseKeywordOrNumber() {
    final start = pos;
    while (!atEnd) {
      final c = _peek();
      if (_isWhitespace(c) || _isDelimiter(c)) break;
      pos += 1;
    }
    final token = String.fromCharCodes(data.sublist(start, pos));
    if (token == 'true') return const PdfBool(true);
    if (token == 'false') return const PdfBool(false);
    if (token == 'null') return const PdfNull();

    final number = num.tryParse(token);
    if (number == null) {
      // 未知关键字：当作名字处理，避免整份文件解析失败
      return PdfName(token);
    }

    // 可能是引用：先记下数字，再看后面是不是「数字 R」
    final save = pos;
    skipWhitespace();
    final secondStart = pos;
    while (!atEnd) {
      final c = _peek();
      if (_isWhitespace(c) || _isDelimiter(c)) break;
      pos += 1;
    }
    final second = String.fromCharCodes(data.sublist(secondStart, pos));
    final secondNumber = int.tryParse(second);
    if (secondNumber != null) {
      skipWhitespace();
      if (_peek() == 0x52) {
        final afterR = _peek(1);
        if (afterR == -1 || _isWhitespace(afterR) || _isDelimiter(afterR)) {
          pos += 1; // 'R'
          return PdfRef(number.toInt(), secondNumber);
        }
      }
    }
    pos = save;
    return PdfNumber(number);
  }

  /// 解析 `N G obj ... endobj`，返回对象号与对象内容。
  ///
  /// 若对象是流，返回 [PdfStream]（含原始字节）。
  ({int number, int generation, PdfObject object}) parseIndirectObject() {
    skipWhitespace();
    final number = _readInteger();
    final generation = _readInteger();
    _expectKeyword('obj');
    final object = parseObject();

    skipWhitespace();
    if (object is PdfDict && _matchKeyword('stream')) {
      // stream 关键字后必须跟 CRLF 或 LF
      if (_peek() == 0x0D) pos += 1;
      if (_peek() == 0x0A) pos += 1;
      final start = pos;
      final length = _streamLength(object);
      Uint8List raw;
      if (length != null && start + length <= data.length) {
        raw = Uint8List.sublistView(data, start, start + length);
        pos = start + length;
      } else {
        // 退而求其次：找 endstream
        final end = _indexOfAscii('endstream', start);
        if (end < 0) throw PdfSyntaxException('流未闭合', start);
        var stop = end;
        if (stop > start && data[stop - 1] == 0x0A) stop -= 1;
        if (stop > start && data[stop - 1] == 0x0D) stop -= 1;
        raw = Uint8List.sublistView(data, start, stop);
        pos = end;
      }
      return (number: number, generation: generation, object: PdfStream(object, raw));
    }
    return (number: number, generation: generation, object: object);
  }

  int? _streamLength(PdfDict dict) {
    final value = dict['Length'];
    if (value is PdfNumber) return value.value.toInt();
    return null;
  }

  int _readInteger() {
    skipWhitespace();
    final start = pos;
    while (!atEnd && !_isWhitespace(_peek()) && !_isDelimiter(_peek())) {
      pos += 1;
    }
    final value = int.tryParse(String.fromCharCodes(data.sublist(start, pos)));
    if (value == null) throw PdfSyntaxException('期待整数', start);
    return value;
  }

  void _expectKeyword(String keyword) {
    skipWhitespace();
    if (!_matchKeyword(keyword)) {
      throw PdfSyntaxException('期待关键字 $keyword', pos);
    }
  }

  bool _matchKeyword(String keyword) {
    final bytes = ascii.encode(keyword);
    if (pos + bytes.length > data.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (data[pos + i] != bytes[i]) return false;
    }
    final after = _peek(bytes.length);
    if (after != -1 && !_isWhitespace(after) && !_isDelimiter(after)) return false;
    pos += bytes.length;
    return true;
  }

  int _indexOfAscii(String needle, int from) {
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

/// 在缓冲区里从后往前查找 `startxref` 后的偏移。
int findLastStartXref(Uint8List data) {
  final marker = ascii.encode('startxref');
  for (var i = data.length - marker.length; i >= 0; i--) {
    var matched = true;
    for (var k = 0; k < marker.length; k++) {
      if (data[i + k] != marker[k]) {
        matched = false;
        break;
      }
    }
    if (!matched) continue;
    final parser = PdfParser(data, i + marker.length);
    parser.skipWhitespace();
    try {
      return parser._readInteger();
    } on PdfSyntaxException {
      continue;
    }
  }
  throw PdfSyntaxException('找不到 startxref');
}
