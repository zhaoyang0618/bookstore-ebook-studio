/// MyLibrary 数据契约的 Dart 镜像（设计文档第一部分）。
///
/// 这些类型与 `@bookstore/mylibrary-core`（TypeScript）**逐字段一致**，
/// 是两个软件能读写同一份数据的根本保证（设计文档 4.3「接口是契约，实现是自由的」）。
///
/// JSON 序列化用手写的 `fromJson` / `toJson`，不依赖代码生成，
/// 保证任何 Dart 环境（包括纯 Dart 脚本）都能用。
library;

/// 同步状态（设计文档 1.4 `sync_state`）。
enum SyncState {
  synced,
  localOnly,
  partial,
  missing;

  /// JSON 里的字面量。
  String get wire => switch (this) {
        SyncState.synced => 'synced',
        SyncState.localOnly => 'local_only',
        SyncState.partial => 'partial',
        SyncState.missing => 'missing',
      };

  /// 从 JSON 字面量解析；未知值落到 [missing]（明确状态而非报错，设计文档 1.1 原则四）。
  static SyncState fromWire(String? value) => switch (value) {
        'synced' => SyncState.synced,
        'local_only' => SyncState.localOnly,
        'partial' => SyncState.partial,
        _ => SyncState.missing,
      };

  /// 排序权重：越"可达"越大（合并时取更可达的一方，设计文档 1.8.2）。
  int get rank => switch (this) {
        SyncState.missing => 0,
        SyncState.localOnly => 1,
        SyncState.partial => 2,
        SyncState.synced => 3,
      };
}

/// 书籍格式。
enum BookFormat {
  epub,
  pdf,
  markdown,
  txt;

  String get wire => name == 'markdown' ? 'markdown' : name;

  static BookFormat fromWire(String? value) => switch (value) {
        'epub' => BookFormat.epub,
        'pdf' => BookFormat.pdf,
        'md' || 'markdown' => BookFormat.markdown,
        'txt' => BookFormat.txt,
        _ => throw FormatException('不支持的书籍格式: $value'),
      };
}

/// 客户端类型（manifest.json）。
enum ClientType {
  dshExtension,
  flutterApp,
  cli,
  other;

  String get wire => switch (this) {
        ClientType.dshExtension => 'dsh-extension',
        ClientType.flutterApp => 'flutter-app',
        ClientType.cli => 'cli',
        ClientType.other => 'other',
      };

  static ClientType fromWire(String? value) => switch (value) {
        'dsh-extension' => ClientType.dshExtension,
        'flutter-app' => ClientType.flutterApp,
        'cli' => ClientType.cli,
        _ => ClientType.other,
      };
}

/// 客户端平台。
enum ClientPlatform {
  macos,
  windows,
  ipad,
  android,
  linux,
  web;

  String get wire => name;

  static ClientPlatform fromWire(String? value) =>
      ClientPlatform.values.firstWhere((p) => p.wire == value, orElse: () => ClientPlatform.web);
}

/// manifest.json（设计文档 1.3）。
class Manifest {
  const Manifest({
    required this.schemaVersion,
    required this.libraryVersion,
    required this.updatedAt,
    required this.updatedBy,
    required this.clients,
  });

  final String schemaVersion;
  final int libraryVersion;
  final String updatedAt;
  final String updatedBy;
  final List<ManifestClient> clients;

  factory Manifest.fromJson(Map<String, dynamic> json) => Manifest(
        schemaVersion: json['schema_version'] as String? ?? '1.0',
        libraryVersion: (json['library_version'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at'] as String? ?? '',
        updatedBy: json['updated_by'] as String? ?? '',
        clients: (json['clients'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(ManifestClient.fromJson)
                .toList() ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'library_version': libraryVersion,
        'updated_at': updatedAt,
        'updated_by': updatedBy,
        'clients': clients.map((c) => c.toJson()).toList(),
      };

  /// 记录一个客户端上线（不存在则新增，存在则刷新 last_seen）。
  Manifest touchClient(ManifestClient client, String now) {
    final existing = clients.where((c) => c.id == client.id);
    final next = existing.isEmpty
        ? [...clients, ManifestClient(id: client.id, type: client.type, platform: client.platform, lastSeen: now)]
        : clients
            .map((c) => c.id == client.id
                ? ManifestClient(id: c.id, type: client.type, platform: client.platform, lastSeen: now)
                : c)
            .toList();
    return Manifest(
      schemaVersion: schemaVersion,
      libraryVersion: libraryVersion + 1,
      updatedAt: now,
      updatedBy: client.id,
      clients: next,
    );
  }
}

/// manifest.json 中的一个客户端条目。
class ManifestClient {
  const ManifestClient({
    required this.id,
    required this.type,
    required this.platform,
    required this.lastSeen,
  });

  final String id;
  final ClientType type;
  final ClientPlatform platform;
  final String lastSeen;

  factory ManifestClient.fromJson(Map<String, dynamic> json) => ManifestClient(
        id: json['id'] as String? ?? '',
        type: ClientType.fromWire(json['type'] as String?),
        platform: ClientPlatform.fromWire(json['platform'] as String?),
        lastSeen: json['last_seen'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.wire,
        'platform': platform.wire,
        'last_seen': lastSeen,
      };
}

/// 持有某本书文件本体的客户端记录。
class BookHolder {
  const BookHolder({required this.clientId, required this.lastSeen});

  final String clientId;
  final String lastSeen;

  factory BookHolder.fromJson(Map<String, dynamic> json) => BookHolder(
        clientId: json['client_id'] as String? ?? '',
        lastSeen: json['last_seen'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'client_id': clientId, 'last_seen': lastSeen};
}

/// 阅读位置。
class ReadingPosition {
  const ReadingPosition({
    required this.position,
    required this.percentage,
    required this.updatedAt,
    required this.updatedBy,
  });

  final String position;
  final double percentage;
  final String updatedAt;
  final String updatedBy;

  factory ReadingPosition.fromJson(Map<String, dynamic> json) => ReadingPosition(
        position: json['position'] as String? ?? '',
        percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
        updatedAt: json['updated_at'] as String? ?? '',
        updatedBy: json['updated_by'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'position': position,
        'percentage': percentage,
        'updated_at': updatedAt,
        'updated_by': updatedBy,
      };
}

/// 一本书的五个独立同步维度（设计文档 1.4）。
class BookSyncState {
  const BookSyncState({
    required this.metadata,
    required this.cover,
    required this.notes,
    required this.file,
    required this.recordings,
  });

  final SyncState metadata;
  final SyncState cover;
  final SyncState notes;
  final SyncState file;
  final SyncState recordings;

  factory BookSyncState.fromJson(Map<String, dynamic> json) => BookSyncState(
        metadata: SyncState.fromWire(json['metadata'] as String?),
        cover: SyncState.fromWire(json['cover'] as String?),
        notes: SyncState.fromWire(json['notes'] as String?),
        file: SyncState.fromWire(json['file'] as String?),
        recordings: SyncState.fromWire(json['recordings'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'metadata': metadata.wire,
        'cover': cover.wire,
        'notes': notes.wire,
        'file': file.wire,
        'recordings': recordings.wire,
      };

  /// 合并两端的 sync_state：每个维度取更"可达"的一方（设计文档 1.8.2）。
  BookSyncState mergeWith(BookSyncState other) => BookSyncState(
        metadata: metadata.rank >= other.metadata.rank ? metadata : other.metadata,
        cover: cover.rank >= other.cover.rank ? cover : other.cover,
        notes: notes.rank >= other.notes.rank ? notes : other.notes,
        file: file.rank >= other.file.rank ? file : other.file,
        recordings: recordings.rank >= other.recordings.rank ? recordings : other.recordings,
      );
}

/// 书籍元数据条目（设计文档 1.4）。
class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.relativePath,
    required this.sizeBytes,
    required this.addedAt,
    required this.syncState,
    required this.heldBy,
    this.coverPath,
    this.notesPath,
    this.recordingsDir,
    this.fileHash,
    this.readingPosition,
    this.tags = const [],
    this.collections = const [],
    this.linkedWikiPages = const [],
  });

  final String id;
  final String title;
  final String author;
  final BookFormat format;

  /// 相对 MyLibrary 根的路径，如 `books/三体/三体.epub`。
  final String relativePath;
  final String? coverPath;
  final String? notesPath;
  final String? recordingsDir;
  final int sizeBytes;
  final String? fileHash;
  final String addedAt;
  final BookSyncState syncState;
  final List<BookHolder> heldBy;
  final ReadingPosition? readingPosition;
  final List<String> tags;
  final List<String> collections;
  final List<String> linkedWikiPages;

  /// 由文件路径推导一本新书的元数据（设计文档 3.4 本地导入）。
  factory Book.fromFile({
    required String id,
    required String title,
    required String author,
    required String relativePath,
    required int sizeBytes,
    String? fileHash,
    String? now,
    BookFormat? format,
  }) {
    final timestamp = now ?? DateTime.now().toUtc().toIso8601String();
    final bookDir = relativePath.replaceAll(RegExp(r'/[^/]*$'), '');
    final fileStem = relativePath.replaceAll(RegExp(r'\.[^./]+$'), '');
    final detected = format ?? BookFormat.fromWire(relativePath.split('.').last);
    return Book(
      id: id,
      title: title,
      author: author,
      format: detected,
      relativePath: relativePath,
      coverPath: '$bookDir/cover.jpg',
      notesPath: '$fileStem.notes.json',
      recordingsDir: '$bookDir/recordings/',
      sizeBytes: sizeBytes,
      fileHash: fileHash,
      addedAt: timestamp,
      syncState: const BookSyncState(
        metadata: SyncState.synced,
        cover: SyncState.localOnly,
        notes: SyncState.localOnly,
        file: SyncState.localOnly,
        recordings: SyncState.localOnly,
      ),
      heldBy: const [],
    );
  }

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        format: BookFormat.fromWire(json['format'] as String?),
        relativePath: json['relative_path'] as String? ?? '',
        coverPath: json['cover_path'] as String?,
        notesPath: json['notes_path'] as String?,
        recordingsDir: json['recordings_dir'] as String?,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        fileHash: json['file_hash'] as String?,
        addedAt: json['added_at'] as String? ?? '',
        syncState: BookSyncState.fromJson((json['sync_state'] as Map<String, dynamic>?) ?? const {}),
        heldBy: (json['held_by'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(BookHolder.fromJson)
                .toList() ??
            const [],
        readingPosition: (json['reading_position'] as Map<String, dynamic>?) != null
            ? ReadingPosition.fromJson(json['reading_position'] as Map<String, dynamic>)
            : null,
        tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
        collections: (json['collections'] as List?)?.whereType<String>().toList() ?? const [],
        linkedWikiPages: (json['linked_wiki_pages'] as List?)?.whereType<String>().toList() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'format': format.wire,
        'relative_path': relativePath,
        if (coverPath != null) 'cover_path': coverPath,
        if (notesPath != null) 'notes_path': notesPath,
        if (recordingsDir != null) 'recordings_dir': recordingsDir,
        'size_bytes': sizeBytes,
        if (fileHash != null) 'file_hash': fileHash,
        'added_at': addedAt,
        'sync_state': syncState.toJson(),
        'held_by': heldBy.map((h) => h.toJson()).toList(),
        if (readingPosition != null) 'reading_position': readingPosition!.toJson(),
        'tags': tags,
        'collections': collections,
        'linked_wiki_pages': linkedWikiPages,
      };

  /// 阅读进度（0 ~ 1）。
  double get percentage => readingPosition?.percentage ?? 0;
}

/// 用户收藏夹。
class Collection {
  const Collection({required this.id, required this.name, required this.createdAt});

  final String id;
  final String name;
  final String createdAt;

  factory Collection.fromJson(Map<String, dynamic> json) => Collection(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'created_at': createdAt};
}

/// 用户标签。
class Tag {
  const Tag({required this.name, required this.createdAt});

  final String name;
  final String createdAt;

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
        name: json['name'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'created_at': createdAt};
}

/// library.json（设计文档 1.4，权威数据源）。
class Library {
  const Library({
    required this.schemaVersion,
    required this.version,
    required this.updatedAt,
    required this.updatedBy,
    required this.books,
    required this.collections,
    required this.tags,
  });

  final String schemaVersion;
  final int version;
  final String updatedAt;
  final String updatedBy;
  final List<Book> books;
  final List<Collection> collections;
  final List<Tag> tags;

  factory Library.fromJson(Map<String, dynamic> json) => Library(
        schemaVersion: json['schema_version'] as String? ?? '1.0',
        version: (json['version'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at'] as String? ?? '',
        updatedBy: json['updated_by'] as String? ?? '',
        books: (json['books'] as List?)?.whereType<Map<String, dynamic>>().map(Book.fromJson).toList() ?? const [],
        collections: (json['collections'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(Collection.fromJson)
                .toList() ??
            const [],
        tags: (json['tags'] as List?)?.whereType<Map<String, dynamic>>().map(Tag.fromJson).toList() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'version': version,
        'updated_at': updatedAt,
        'updated_by': updatedBy,
        'books': books.map((b) => b.toJson()).toList(),
        'collections': collections.map((c) => c.toJson()).toList(),
        'tags': tags.map((t) => t.toJson()).toList(),
      };

  /// 空图书馆。
  factory Library.empty(String clientId) => Library(
        schemaVersion: '1.0',
        version: 1,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        updatedBy: clientId,
        books: const [],
        collections: const [],
        tags: const [],
      );

  Book? findById(String id) {
    for (final book in books) {
      if (book.id == id) return book;
    }
    return null;
  }

  /// 按标题 / 作者 / 标签模糊搜索。
  List<Book> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return books.where((book) {
      final haystack = [book.title, book.author, ...book.tags, ...book.collections].join(' ').toLowerCase();
      return haystack.contains(needle);
    }).toList();
  }

  /// 新增一本书，返回新 Library（不可变更新）。
  Library addBook(Book book, String clientId) => copyWith(
        version: version + 1,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        updatedBy: clientId,
        books: [...books, book],
        tags: mergeTags(tags, book.tags),
      );

  /// 更新一本书。
  Library updateBook(String id, Book Function(Book) patch, String clientId) {
    final index = books.indexWhere((b) => b.id == id);
    if (index < 0) throw StateError('书籍不存在: $id');
    final next = [...books];
    next[index] = patch(next[index]);
    return copyWith(
      version: version + 1,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      updatedBy: clientId,
      books: next,
    );
  }

  Library copyWith({
    int? version,
    String? updatedAt,
    String? updatedBy,
    List<Book>? books,
    List<Collection>? collections,
    List<Tag>? tags,
    String? schemaVersion,
  }) =>
      Library(
        schemaVersion: schemaVersion ?? this.schemaVersion,
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        updatedBy: updatedBy ?? this.updatedBy,
        books: books ?? this.books,
        collections: collections ?? this.collections,
        tags: tags ?? this.tags,
      );

  static List<Tag> mergeTags(List<Tag> existing, List<String> incoming) {
    final byName = {for (final tag in existing) tag.name: tag};
    final now = DateTime.now().toUtc().toIso8601String();
    for (final name in incoming) {
      byName.putIfAbsent(name, () => Tag(name: name, createdAt: now));
    }
    return byName.values.toList();
  }
}
