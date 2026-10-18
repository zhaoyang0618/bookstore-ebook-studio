/// MyLibrary 目录的本地访问层（Dart 侧）。
///
/// 与 `@bookstore/mylibrary-core` 的 `MyLibraryStore` 对应，
/// 读写同一份数据（设计文档 4.2「数据互通场景」）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/mylibrary_models.dart';
import 'sync.dart';

/// MyLibrary 目录结构常量（设计文档 1.2）。
class MyLibraryLayout {
  const MyLibraryLayout._(this.root);

  final String root;

  static const String manifestFile = 'manifest.json';
  static const String libraryFile = 'library.json';
  static const String requestsDir = 'requests';
  static const String wikiDir = 'wiki';
  static const String booksDir = 'books';
  static const String trashDir = '.trash';
  static const String wikiPagesDir = 'pages';
  static const String notesSuffix = '.notes.json';
  static const String recordingsDirname = 'recordings';

  String get manifestPath => p.join(root, manifestFile);
  String get libraryPath => p.join(root, libraryFile);
  String get requestsPath => p.join(root, requestsDir);
  String get wikiIndexPath => p.join(root, wikiDir, 'index.json');
  String get wikiPagesPath => p.join(root, wikiDir, wikiPagesDir);
  String get booksPath => p.join(root, booksDir);
  String get trashPath => p.join(root, trashDir);

  /// 把相对路径解析为绝对路径。
  String absolute(String relativePath) => p.normalize(p.join(root, relativePath));

  /// 由根目录推导布局。
  static MyLibraryLayout of(String root) => MyLibraryLayout._(p.normalize(root));
}

/// 数据层抛出的可预期错误。
class MyLibraryException implements Exception {
  MyLibraryException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MyLibraryException($code): $message';
}

/// 一篇 Wiki 页面（设计文档 1.6）。
class WikiPage {
  const WikiPage({
    required this.id,
    required this.slug,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.tags,
    required this.sourceBooks,
    required this.links,
    required this.body,
    required this.relativePath,
  });

  final String id;
  final String slug;
  final String title;
  final String createdAt;
  final String updatedAt;
  final List<String> tags;
  final List<String> sourceBooks;

  /// frontmatter 里显式声明的出链。
  final List<String> links;

  /// Markdown 正文。
  final String body;
  final String relativePath;

  /// 从正文提取的 `[[双向链接]]` 目标 slug。
  List<String> get wikiLinks => extractWikiLinks(body);

  /// `links` 与正文 `[[]]` 取并集。
  List<String> get allLinks => {...links, ...wikiLinks}.toList();
}

/// 提取 `[[双向链接]]` 目标 slug。
List<String> extractWikiLinks(String body) {
  final links = <String>[];
  final seen = <String>{};
  final pattern = RegExp(r'\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]');
  for (final match in pattern.allMatches(body)) {
    final target = match.group(1)?.trim() ?? '';
    if (target.isEmpty) continue;
    final slug = slugify(target);
    if (seen.add(slug)) links.add(slug);
  }
  return links;
}

/// 把任意标题转成 slug。
String slugify(String title) {
  var result = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (result.isEmpty) {
    result = 'page-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  }
  return result;
}

/// Wiki 图谱（设计文档 2.8）。
class WikiGraph {
  const WikiGraph({required this.nodes, required this.backlinks});

  final List<WikiPage> nodes;

  /// slug → 指向它的页面 slug 列表（反链）。
  final Map<String, List<String>> backlinks;
}

/// 一条批注（设计文档 1.5）。
class Annotation {
  const Annotation({
    required this.id,
    required this.type,
    required this.anchor,
    required this.createdAt,
    required this.updatedAt,
    this.text,
    this.note,
    this.color,
    this.strokes,
  });

  final String id;

  /// `highlight` / `note` / `ink`。
  final String type;
  final Map<String, dynamic> anchor;
  final String createdAt;
  final String updatedAt;
  final String? text;
  final String? note;
  final String? color;

  /// ink 类型的矢量笔迹（点 + 压力 + 时间戳）。
  final List<Map<String, dynamic>>? strokes;

  factory Annotation.fromJson(Map<String, dynamic> json) => Annotation(
        id: json['id'] as String? ?? '',
        type: json['type'] as String? ?? 'highlight',
        anchor: (json['anchor'] as Map<String, dynamic>?) ?? const {},
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
        text: json['text'] as String?,
        note: json['note'] as String?,
        color: json['color'] as String?,
        strokes: (json['strokes'] as List?)?.whereType<Map<String, dynamic>>().toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'anchor': anchor,
        if (text != null) 'text': text,
        if (note != null) 'note': note,
        if (color != null) 'color': color,
        if (strokes != null) 'strokes': strokes,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };
}

/// 笔记边车（设计文档 1.5）。
class NotesSidecar {
  const NotesSidecar({
    required this.bookId,
    required this.bookFormat,
    required this.version,
    required this.updatedAt,
    required this.updatedBy,
    required this.annotations,
  });

  final String bookId;
  final String bookFormat;
  final int version;
  final String updatedAt;
  final String updatedBy;
  final List<Annotation> annotations;

  factory NotesSidecar.empty(String bookId, String bookFormat) => NotesSidecar(
        bookId: bookId,
        bookFormat: bookFormat,
        version: 0,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        updatedBy: '',
        annotations: const [],
      );

  factory NotesSidecar.fromJson(Map<String, dynamic> json) => NotesSidecar(
        bookId: json['book_id'] as String? ?? '',
        bookFormat: json['book_format'] as String? ?? '',
        version: (json['version'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at'] as String? ?? '',
        updatedBy: json['updated_by'] as String? ?? '',
        annotations: (json['annotations'] as List?)?.whereType<Map<String, dynamic>>().map(Annotation.fromJson).toList() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'schema_version': kSchemaVersion,
        'book_id': bookId,
        'book_format': bookFormat,
        'version': version,
        'updated_at': updatedAt,
        'updated_by': updatedBy,
        'annotations': annotations.map((a) => a.toJson()).toList(),
      };
}

/// 一条录课视频元数据（设计文档 1.7）。
class Recording {
  const Recording({
    required this.id,
    required this.bookId,
    required this.title,
    required this.file,
    required this.durationSeconds,
    required this.sizeBytes,
    required this.createdAt,
    required this.createdBy,
    required this.linkedWikiPages,
    this.positionAtStart,
    this.positionAtEnd,
    this.transcript,
  });

  final String id;
  final String bookId;
  final String title;
  final String file;
  final int durationSeconds;
  final int sizeBytes;
  final String createdAt;
  final String createdBy;
  final List<String> linkedWikiPages;
  final String? positionAtStart;
  final String? positionAtEnd;
  final String? transcript;

  factory Recording.fromJson(Map<String, dynamic> json) => Recording(
        id: json['id'] as String? ?? '',
        bookId: json['book_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        file: json['file'] as String? ?? '',
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        createdAt: json['created_at'] as String? ?? '',
        createdBy: json['created_by'] as String? ?? '',
        linkedWikiPages: (json['linked_wiki_pages'] as List?)?.whereType<String>().toList() ?? const [],
        positionAtStart: json['position_at_start'] as String?,
        positionAtEnd: json['position_at_end'] as String?,
        transcript: json['transcript'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_id': bookId,
        'title': title,
        'file': file,
        'duration_seconds': durationSeconds,
        'size_bytes': sizeBytes,
        'created_at': createdAt,
        'created_by': createdBy,
        if (positionAtStart != null) 'position_at_start': positionAtStart,
        if (positionAtEnd != null) 'position_at_end': positionAtEnd,
        'linked_wiki_pages': linkedWikiPages,
        if (transcript != null) 'transcript': transcript,
      };
}

/// MyLibrary 目录的本地访问层。
class MyLibraryStore {
  MyLibraryStore(this.root, {this.clientId = 'flutter-app-client'}) : layout = MyLibraryLayout.of(root);

  /// MyLibrary 根目录。
  final String root;

  /// 本客户端 id。
  final String clientId;
  final MyLibraryLayout layout;

  final JsonEncoder _encoder = const JsonEncoder.withIndent('  ');
  final JsonDecoder _decoder = const JsonDecoder();

  // ---------- 初始化（1.2） ----------

  /// 创建标准目录结构；已存在的目录不覆盖。
  void init() {
    for (final dir in [
      layout.booksPath,
      layout.requestsPath,
      layout.wikiPagesPath,
      p.join(root, MyLibraryLayout.wikiDir, 'attachments', 'images'),
      layout.trashPath,
    ]) {
      Directory(dir).createSync(recursive: true);
    }
    if (!File(layout.manifestPath).existsSync()) {
      writeManifest(Manifest(
        schemaVersion: kSchemaVersion,
        libraryVersion: 1,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        updatedBy: clientId,
        clients: const [],
      ));
    }
    if (!File(layout.libraryPath).existsSync()) {
      writeLibrary(Library.empty(clientId));
    }
  }

  // ---------- manifest.json（1.3） ----------

  Manifest readManifest() {
    final text = _readText(layout.manifestPath, 'manifest.json');
    final check = checkSchemaCompatibility(_decode(text)['schema_version'] as String? ?? kSchemaVersion);
    if (!check.isCompatible) throw MyLibraryException('SCHEMA_INCOMPATIBLE', check.reason);
    return parseManifest(text);
  }

  void writeManifest(Manifest manifest) {
    File(layout.manifestPath).writeAsStringSync('${encodeManifest(manifest)}\n');
  }

  /// 记录本客户端上线。
  Manifest touchClient({
    String? id,
    ClientType type = ClientType.flutterApp,
    ClientPlatform platform = ClientPlatform.ipad,
  }) {
    final manifest = readManifest();
    final client = ManifestClient(
      id: id ?? clientId,
      type: type,
      platform: platform,
      lastSeen: DateTime.now().toUtc().toIso8601String(),
    );
    final next = manifest.touchClient(client, DateTime.now().toUtc().toIso8601String());
    writeManifest(next);
    return next;
  }

  // ---------- library.json（1.4） ----------

  Library readLibrary() {
    final text = _readText(layout.libraryPath, 'library.json');
    final check = checkSchemaCompatibility(_decode(text)['schema_version'] as String? ?? kSchemaVersion);
    if (!check.isCompatible) throw MyLibraryException('SCHEMA_INCOMPATIBLE', check.reason);
    return parseLibrary(text);
  }

  void writeLibrary(Library library) {
    File(layout.libraryPath).writeAsStringSync('${encodeLibrary(library)}\n');
  }

  Book? findBook(String id) => readLibrary().findById(id);

  List<Book> searchBooks(String query) => readLibrary().search(query);

  /// 新增一本书（幂等：同 id 已存在则报错）。
  Book addBook(Book book) {
    final library = readLibrary();
    if (library.findById(book.id) != null) {
      throw MyLibraryException('BOOK_EXISTS', '书籍 id 已存在：${book.id}');
    }
    writeLibrary(library.addBook(book, clientId));
    return book;
  }

  /// 更新一本书。
  Book updateBook(String id, Book Function(Book) patch) {
    final library = readLibrary();
    final updated = library.updateBook(id, patch, clientId);
    writeLibrary(updated);
    return updated.findById(id)!;
  }

  /// 按设计文档 1.8.5 的删除语义删除书籍。
  void deleteBook(String id, DeleteOperation operation) {
    final plan = DeletePlan.of(operation);
    final library = readLibrary();
    final book = library.findById(id);
    if (book == null) throw MyLibraryException('BOOK_NOT_FOUND', '书籍不存在: $id');
    // 书籍目录 = 文件本体所在的目录（一本书的所有资产都在这里）
    final bookDir = layout.absolute(book.relativePath.replaceAll(RegExp(r'/[^/]*$'), ''));
    if (operation == DeleteOperation.deleteBook) {
      final target = p.join(layout.trashPath, 'books', book.id);
      Directory(target).parent.createSync(recursive: true);
      _rename(bookDir, target);
    } else if (plan.file == 'delete') {
      if (Directory(bookDir).existsSync()) Directory(bookDir).deleteSync(recursive: true);
    }
    if (plan.metadata == 'delete') {
      writeLibrary(library.copyWith(
        version: library.version + 1,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        updatedBy: clientId,
        books: library.books.where((b) => b.id != id).toList(),
      ));
    } else {
      updateBook(id, (b) => Book(
            id: b.id,
            title: b.title,
            author: b.author,
            format: b.format,
            relativePath: b.relativePath,
            coverPath: b.coverPath,
            notesPath: b.notesPath,
            recordingsDir: b.recordingsDir,
            sizeBytes: b.sizeBytes,
            fileHash: b.fileHash,
            addedAt: b.addedAt,
            syncState: BookSyncState(
              metadata: b.syncState.metadata,
              cover: b.syncState.cover,
              notes: b.syncState.notes,
              file: plan.nextFileSyncState ?? SyncState.localOnly,
              recordings: b.syncState.recordings,
            ),
            heldBy: b.heldBy.where((h) => h.clientId != clientId).toList(),
            readingPosition: b.readingPosition,
            tags: b.tags,
            collections: b.collections,
            linkedWikiPages: b.linkedWikiPages,
          ));
    }
  }

  // ---------- 笔记边车（1.5） ----------

  /// 读取某本书的笔记边车（不存在时返回空边车）。
  NotesSidecar readNotes(Book book) {
    final path = _notesPath(book);
    if (!File(path).existsSync()) return NotesSidecar.empty(book.id, book.format.wire);
    final json = _decode(_readText(path, '笔记边车'));
    return NotesSidecar.fromJson(json);
  }

  /// 写入某本书的笔记边车。
  NotesSidecar writeNotes(Book book, List<Annotation> annotations) {
    final existing = readNotes(book);
    final next = NotesSidecar(
      bookId: book.id,
      bookFormat: book.format.wire,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      updatedBy: clientId,
      annotations: annotations,
    );
    final path = _notesPath(book);
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync('${_encoder.convert(next.toJson())}\n');
    return next;
  }

  /// 追加一条批注。
  Annotation addAnnotation(Book book, Annotation annotation) {
    final notes = readNotes(book);
    writeNotes(book, [...notes.annotations, annotation]);
    return annotation;
  }

  String _notesPath(Book book) =>
      book.notesPath != null ? layout.absolute(book.notesPath!) : layout.absolute(book.relativePath.replaceAll(RegExp(r'\.[^./]+$'), '')) + MyLibraryLayout.notesSuffix;

  // ---------- Wiki（1.6） ----------

  /// 列出全部 Wiki 页面。
  List<WikiPage> listWikiPages() {
    final dir = Directory(layout.wikiPagesPath);
    if (!dir.existsSync()) return const [];
    final pages = <WikiPage>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      pages.add(parseWikiPage(entity.readAsStringSync(), p.basename(entity.path)));
    }
    pages.sort((a, b) => a.title.compareTo(b.title));
    return pages;
  }

  WikiPage? readWikiPage(String slug) {
    for (final page in listWikiPages()) {
      if (page.slug == slug) return page;
    }
    return null;
  }

  /// 写入一个 Wiki 页面（按 slug 命名）。
  WikiPage writeWikiPage(WikiPage page) {
    final path = p.join(layout.wikiPagesPath, page.relativePath);
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(stringifyWikiPage(page));
    return page;
  }

  /// 重建 wiki/index.json（设计文档 1.6：索引可从 pages/ 重建）。
  void rebuildWikiIndex() {
    final pages = listWikiPages();
    final index = {
      'schema_version': kSchemaVersion,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'pages': pages
          .map((page) => {
                'id': page.id,
                'slug': page.slug,
                'title': page.title,
                'path': page.relativePath,
                'updated_at': page.updatedAt,
                'tags': page.tags,
                'source_books': page.sourceBooks,
                'links': page.allLinks,
              })
          .toList(),
    };
    File(layout.wikiIndexPath).writeAsStringSync('${_encoder.convert(index)}\n');
  }

  /// 构建 Wiki 双向链接图谱。
  WikiGraph buildWikiGraph() {
    final pages = listWikiPages();
    final backlinks = <String, List<String>>{};
    final known = pages.map((page) => page.slug).toSet();
    for (final page in pages) {
      for (final target in page.allLinks) {
        if (!known.contains(target)) continue;
        backlinks.putIfAbsent(target, () => []).add(page.slug);
      }
    }
    return WikiGraph(nodes: pages, backlinks: backlinks);
  }

  // ---------- 录课视频（1.7） ----------

  List<Recording> listRecordings(Book book) {
    final dir = book.recordingsDir != null ? layout.absolute(book.recordingsDir!) : null;
    if (dir == null || !Directory(dir).existsSync()) return const [];
    final recordings = <Recording>[];
    for (final entity in Directory(dir).listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.json') || name.endsWith('.parts.json') || name == 'upload.json') continue;
      final json = _decode(entity.readAsStringSync());
      recordings.add(Recording.fromJson(json));
    }
    return recordings;
  }

  /// 写入一条录课视频元数据（与视频文件同名）。
  void writeRecording(Recording recording) {
    final book = findBook(recording.bookId);
    final base = book != null
        ? layout.absolute(book.relativePath.replaceAll(RegExp(r'/[^/]*$'), ''))
        : p.join(layout.booksPath, recording.bookId);
    final dir = p.join(base, MyLibraryLayout.recordingsDirname);
    Directory(dir).createSync(recursive: true);
    final jsonName = recording.file.replaceAll(RegExp(r'\.[^.]+$'), '.json');
    File(p.join(dir, jsonName)).writeAsStringSync('${_encoder.convert(recording.toJson())}\n');
  }

  /// 大文件分片上传的进度文件（1.8.6）。
  String partsDir(String fileName, String bookId) => p.join(layout.booksPath, bookId, MyLibraryLayout.recordingsDirname, '$fileName.parts');

  // ---------- 同步请求队列（1.8.4） ----------

  List<SyncRequest> listSyncRequests() {
    final dir = Directory(layout.requestsPath);
    if (!dir.existsSync()) return const [];
    final requests = <SyncRequest>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      requests.add(SyncRequest.fromJson(_decode(entity.readAsStringSync())));
    }
    return requests;
  }

  void writeSyncRequest(SyncRequest request) {
    File(p.join(layout.requestsPath, '${request.id}.json')).writeAsStringSync('${_encoder.convert(request.toJson())}\n');
  }

  /// 完成一条同步请求（删除请求文件）。
  void fulfillSyncRequest(String requestId) {
    final file = File(p.join(layout.requestsPath, '$requestId.json'));
    if (file.existsSync()) file.deleteSync();
  }

  /// 挑出针对其它客户端的待处理请求。
  List<SyncRequest> pendingRequests() => listSyncRequests().where((r) => r.isPendingFor(clientId)).toList();

  // ---------- 迁移（1.9） ----------

  /// 迁移到当前 schema 版本，迁移前自动备份到 `.trash/schema-migration-{date}/`。
  ({String? backedUpTo, List<String> migrated}) migrate() {
    final migrated = <String>[];
    String? backedUpTo;

    void migrateFile(String path, void Function(Map<String, dynamic>) write) {
      if (!File(path).existsSync()) return;
      final json = _decode(File(path).readAsStringSync());
      final current = json['schema_version'] as String?;
      if (current == kSchemaVersion) return;
      backedUpTo ??= p.join(layout.trashPath, 'schema-migration-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}');
      final target = p.join(backedUpTo!, p.relative(path, from: root));
      File(target).parent.createSync(recursive: true);
      _rename(path, target);
      json['schema_version'] = kSchemaVersion;
      write(json);
      migrated.add(p.basename(path));
    }

    migrateFile(layout.manifestPath, (json) => File(layout.manifestPath).writeAsStringSync('${_encoder.convert(json)}\n'));
    migrateFile(layout.libraryPath, (json) => File(layout.libraryPath).writeAsStringSync('${_encoder.convert(json)}\n'));
    return (backedUpTo: backedUpTo, migrated: migrated);
  }

  // ---------- 内部工具 ----------

  String _readText(String path, String subject) {
    final file = File(path);
    if (!file.existsSync()) throw MyLibraryException('FILE_NOT_FOUND', '$subject 不存在: $path');
    return file.readAsStringSync();
  }

  Map<String, dynamic> _decode(String text) {
    final decoded = _decoder.convert(text);
    if (decoded is! Map<String, dynamic>) throw MyLibraryException('JSON_PARSE_FAILED', '不是合法的 JSON 对象');
    return decoded;
  }

  void _rename(String from, String to) {
    if (File(from).existsSync()) {
      File(from).renameSync(to);
    } else if (Directory(from).existsSync()) {
      Directory(from).renameSync(to);
    }
  }
}


/// 去掉 YAML 值两侧的引号。
String _stripQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) || (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// 把解析出的值安全转成字符串列表。
List<String> _asStringList(dynamic value) {
  if (value is List) return value.map((item) => item.toString()).toList();
  if (value is String && value.isNotEmpty) return [value];
  return const [];
}

/// 解析一个 Wiki 页面文件。
WikiPage parseWikiPage(String content, String relativePath) {
  final match = RegExp(r'^---\s*\n([\s\S]*?)\n---\s*\n?([\s\S]*)$').firstMatch(content);
  if (match == null) throw MyLibraryException('WIKI_PARSE_FAILED', 'Wiki 页面 $relativePath 缺少 frontmatter');
  final yaml = match.group(1) ?? '';
  final body = (match.group(2) ?? '').replaceFirst(RegExp(r'^\n+'), '');
  final raw = <String, dynamic>{};

  // 支持两种列表写法（与 TS 版 parseFrontmatter 一致）：
  //   行内：tags: [三体, 人物]
  //   块状：links:
  //           - dark-forest
  String? pendingListKey;
  var pendingList = <String>[];

  void flushPending() {
    if (pendingListKey != null) raw[pendingListKey!] = pendingList;
    pendingListKey = null;
    pendingList = <String>[];
  }

  for (final line in yaml.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    // 块状列表项
    final listItem = RegExp(r'^-\s+(.*)$').firstMatch(trimmed);
    if (listItem != null && pendingListKey != null) {
      pendingList.add(_stripQuotes(listItem.group(1)!.trim()));
      continue;
    }

    final kv = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$').firstMatch(trimmed);
    if (kv == null) continue;
    flushPending();
    final key = kv.group(1)!;
    final value = kv.group(2)!.trim();
    if (value.isEmpty) {
      // 可能是后续的块状列表
      pendingListKey = key;
      pendingList = <String>[];
    } else if (value.startsWith('[') && value.endsWith(']')) {
      final inner = value.substring(1, value.length - 1).trim();
      raw[key] = inner.isEmpty
          ? <String>[]
          : inner.split(',').map((item) => _stripQuotes(item.trim())).where((item) => item.isNotEmpty).toList();
    } else {
      raw[key] = _stripQuotes(value);
    }
  }
  flushPending();

  return WikiPage(
    id: raw['id'] as String? ?? '',
    slug: raw['slug'] as String? ?? slugify(raw['title'] as String? ?? relativePath),
    title: raw['title'] as String? ?? relativePath.replaceAll('.md', ''),
    createdAt: raw['created_at'] as String? ?? '',
    updatedAt: raw['updated_at'] as String? ?? '',
    tags: _asStringList(raw['tags']),
    sourceBooks: _asStringList(raw['source_books']),
    links: _asStringList(raw['links']),
    body: body,
    relativePath: relativePath,
  );
}

/// 序列化一个 Wiki 页面为文件内容。
String stringifyWikiPage(WikiPage page) {
  final body = page.body.replaceFirst(RegExp(r'^\n+'), '').replaceFirst(RegExp(r'\s+$'), '');
  return '---\n'
      'id: ${page.id}\n'
      'slug: ${page.slug}\n'
      'title: ${page.title}\n'
      'created_at: ${page.createdAt}\n'
      'updated_at: ${page.updatedAt}\n'
      'tags: [${page.tags.join(', ')}]\n'
      'source_books: [${page.sourceBooks.join(', ')}]\n'
      'links: [${page.links.join(', ')}]\n'
      '---\n\n'
      '$body\n';
}

/// 新建一个 Wiki 页面。
WikiPage createWikiPage({
  required String id,
  required String title,
  String? body,
  List<String> tags = const [],
  List<String> sourceBooks = const [],
  String? now,
  String? relativePath,
}) {
  final timestamp = now ?? DateTime.now().toUtc().toIso8601String();
  final slug = slugify(title);
  return WikiPage(
    id: id,
    slug: slug,
    title: title,
    createdAt: timestamp,
    updatedAt: timestamp,
    tags: tags,
    sourceBooks: sourceBooks,
    links: const [],
    body: body ?? '# $title\n',
    relativePath: relativePath ?? '$slug.md',
  );
}

/// 读取二进制文件（供 PDF / EPUB 引擎用）。
Uint8List readBinary(String path) => File(path).readAsBytesSync();

/// 写回二进制文件（供 PDF 注释用，设计文档 3.3）。
void writeBinary(String path, Uint8List data) {
  File(path).parent.createSync(recursive: true);
  File(path).writeAsBytesSync(data);
}
