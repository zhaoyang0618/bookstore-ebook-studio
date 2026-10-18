/// 同步机制（设计文档 1.8）的 Dart 实现。
///
/// 与 `@bookstore/mylibrary-core`（TypeScript）的 `sync.ts` **逻辑一致**，
/// 保证两个软件对同一份数据得到相同的合并结果。
library;

import 'dart:convert';

import '../models/mylibrary_models.dart';

/// 版本对比结论。
enum VersionComparison {
  remoteNewer,
  equal,
  localNewer;

  static VersionComparison of(int localVersion, int remoteVersion) {
    if (remoteVersion > localVersion) return VersionComparison.remoteNewer;
    if (remoteVersion < localVersion) return VersionComparison.localNewer;
    return VersionComparison.equal;
  }
}

/// 同步计划（设计文档 1.8.1）。
class SyncPlan {
  const SyncPlan({
    required this.comparison,
    required this.localVersion,
    required this.remoteVersion,
  });

  final VersionComparison comparison;
  final int localVersion;
  final int remoteVersion;

  String get action => switch (comparison) {
        VersionComparison.remoteNewer => 'download',
        VersionComparison.localNewer => 'upload',
        VersionComparison.equal => 'none',
      };

  String get reason => switch (comparison) {
        VersionComparison.remoteNewer => '网盘版本高于本地，下载 JSON 并重建本地索引',
        VersionComparison.localNewer => '本地有未上传修改，推送到网盘',
        VersionComparison.equal => '版本一致，无需同步',
      };

  factory SyncPlan.compare(Library local, Library remote) =>
      SyncPlan(comparison: VersionComparison.of(local.version, remote.version), localVersion: local.version, remoteVersion: remote.version);
}

/// 一次合并动作的记录。
class MergeAction {
  const MergeAction({required this.kind, required this.path, required this.message});

  final String kind;
  final String path;
  final String message;

  Map<String, dynamic> toJson() => {'kind': kind, 'path': path, 'message': message};
}

/// 合并结果。
class MergeResult {
  const MergeResult({required this.value, required this.actions});

  final Library value;
  final List<MergeAction> actions;

  bool get hasUnresolvedConflicts => actions.any((a) => a.kind == 'unmerged');
}

/// 冲突合并策略。
enum ConflictStrategy { auto, latestWins, keepBoth, manual }

/// 两个可选值中取 `updated_at` 较新的一方。
T? pickLatest<T extends Object>(T? local, T? remote, String Function(T) updatedAtOf) {
  if (local == null) return remote;
  if (remote == null) return local;
  final a = DateTime.tryParse(updatedAtOf(local));
  final b = DateTime.tryParse(updatedAtOf(remote));
  if (a == null || b == null) return local;
  return b.isAfter(a) ? remote : local;
}

/// 合并两个 `held_by` 列表：取并集，按 last_seen 降序。
List<BookHolder> mergeHolders(List<BookHolder> local, List<BookHolder> remote) {
  final byClient = <String, BookHolder>{};
  for (final holder in [...local, ...remote]) {
    final existing = byClient[holder.clientId];
    if (existing == null) {
      byClient[holder.clientId] = holder;
      continue;
    }
    final a = DateTime.tryParse(existing.lastSeen);
    final b = DateTime.tryParse(holder.lastSeen);
    if (a == null || b == null || b.isAfter(a)) byClient[holder.clientId] = holder;
  }
  final list = byClient.values.toList()
    ..sort((x, y) {
      final a = DateTime.tryParse(x.lastSeen);
      final b = DateTime.tryParse(y.lastSeen);
      if (a == null || b == null) return 0;
      return b.compareTo(a);
    });
  return list;
}

/// 合并阅读位置：按 updated_at 取最新。
ReadingPosition? mergeReadingPosition(ReadingPosition? local, ReadingPosition? remote) =>
    pickLatest<ReadingPosition>(local, remote, (p) => p.updatedAt);

/// 字符串数组合并（取并集，顺序稳定）。
List<String>? mergeStringUnions(List<String>? local, List<String>? remote) {
  if (local == null && remote == null) return null;
  return {...local ?? const <String>[], ...remote ?? const <String>[]}.toList();
}

/// 合并两端同一本书（设计文档 1.8.2：字段级合并）。
Book mergeBook(Book local, Book remote, ConflictStrategy strategy, List<MergeAction> actions) {
  final path = 'books/${local.id}';
  final position = mergeReadingPosition(local.readingPosition, remote.readingPosition);
  final merged = Book(
    id: local.id,
    // 标量字段：远端覆盖（版本对比阶段已保证只有一端写入时无冲突）
    title: remote.title.isNotEmpty ? remote.title : local.title,
    author: remote.author.isNotEmpty ? remote.author : local.author,
    format: local.format,
    relativePath: local.relativePath,
    coverPath: local.coverPath,
    notesPath: local.notesPath,
    recordingsDir: local.recordingsDir,
    sizeBytes: local.sizeBytes > remote.sizeBytes ? local.sizeBytes : remote.sizeBytes,
    fileHash: local.fileHash ?? remote.fileHash,
    addedAt: local.addedAt,
    syncState: local.syncState.mergeWith(remote.syncState),
    heldBy: mergeHolders(local.heldBy, remote.heldBy),
    readingPosition: position,
    tags: mergeStringUnions(local.tags, remote.tags) ?? const [],
    collections: mergeStringUnions(local.collections, remote.collections) ?? const [],
    linkedWikiPages: mergeStringUnions(local.linkedWikiPages, remote.linkedWikiPages) ?? const [],
  );
  final localHash = local.fileHash;
  final remoteHash = remote.fileHash;
  if (localHash != null && remoteHash != null && localHash != remoteHash && strategy != ConflictStrategy.auto) {
    actions.add(MergeAction(
      kind: 'unmerged',
      path: '$path/file_hash',
      message: '《${local.title}》文件哈希不一致：本地 $localHash / 网盘 $remoteHash',
    ));
  }
  return merged;
}

/// 合并两个 library.json（设计文档 1.8.2）。
MergeResult mergeLibraries(Library local, Library remote, [ConflictStrategy strategy = ConflictStrategy.auto]) {
  final actions = <MergeAction>[];
  final byId = <String, Book>{for (final book in local.books) book.id: book};
  for (final remoteBook in remote.books) {
    final localBook = byId[remoteBook.id];
    if (localBook == null) {
      byId[remoteBook.id] = remoteBook;
      actions.add(MergeAction(kind: 'book-added', path: 'books/${remoteBook.id}', message: '新增书籍《${remoteBook.title}》'));
      continue;
    }
    byId[remoteBook.id] = mergeBook(localBook, remoteBook, strategy, actions);
  }

  // collections / tags 取并集
  final collectionIds = {for (final c in local.collections) c.id};
  final collections = [...local.collections, ...remote.collections.where((c) => !collectionIds.contains(c.id))];
  final tagNames = {for (final t in local.tags) t.name};
  final tags = [...local.tags, ...remote.tags.where((t) => !tagNames.contains(t.name))];

  // 元信息：version 取较大值，updated_at 取最新（解析失败时视为更旧）
  final localTime = DateTime.tryParse(local.updatedAt);
  final remoteTime = DateTime.tryParse(remote.updatedAt);
  final newer = (remoteTime != null && (localTime == null || remoteTime.isAfter(localTime))) ? remote : local;
  final merged = Library(
    schemaVersion: local.schemaVersion,
    version: local.version > remote.version ? local.version : remote.version,
    updatedAt: newer.updatedAt,
    updatedBy: newer.updatedBy,
    books: byId.values.toList(),
    collections: collections,
    tags: tags,
  );
  return MergeResult(value: merged, actions: actions);
}

/// 同步请求（设计文档 1.8.4）。
class SyncRequest {
  const SyncRequest({
    required this.id,
    required this.bookId,
    required this.requestedBy,
    required this.requestedAt,
    required this.status,
  });

  final String id;
  final String bookId;
  final String requestedBy;
  final String requestedAt;
  final String status;

  factory SyncRequest.fromJson(Map<String, dynamic> json) => SyncRequest(
        id: json['id'] as String? ?? '',
        bookId: json['book_id'] as String? ?? '',
        requestedBy: json['requested_by'] as String? ?? '',
        requestedAt: json['requested_at'] as String? ?? '',
        status: json['status'] as String? ?? 'pending',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_id': bookId,
        'requested_by': requestedBy,
        'requested_at': requestedAt,
        'status': status,
      };

  /// 挑出针对某个客户端的待处理请求。
  bool isPendingFor(String clientId) => status == 'pending' && requestedBy != clientId;
}

/// 生成一个同步请求文件名。
String syncRequestFileName(String bookId, String clientId) => 'sync-req-$bookId-$clientId.json';

/// 构造一条同步请求。
SyncRequest createSyncRequest(String bookId, String clientId, {String? id}) => SyncRequest(
      id: id ?? 'sync-req-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      bookId: bookId,
      requestedBy: clientId,
      requestedAt: DateTime.now().toUtc().toIso8601String(),
      status: 'pending',
    );

/// 删除操作（设计文档 1.8.5）。
enum DeleteOperation {
  removeEntry,
  deleteBook,
  deleteLocalOnly,
  cancelSync;

  String get wire => switch (this) {
        DeleteOperation.removeEntry => 'remove_entry',
        DeleteOperation.deleteBook => 'delete_book',
        DeleteOperation.deleteLocalOnly => 'delete_local_only',
        DeleteOperation.cancelSync => 'cancel_sync',
      };
}

/// 删除计划。
class DeletePlan {
  const DeletePlan({
    required this.operation,
    required this.metadata,
    required this.file,
    required this.description,
    this.nextFileSyncState,
  });

  final DeleteOperation operation;

  /// `keep` / `delete`。
  final String metadata;

  /// `keep` / `trash` / `delete`。
  final String file;
  final SyncState? nextFileSyncState;
  final String description;

  factory DeletePlan.of(DeleteOperation operation) => switch (operation) {
        DeleteOperation.removeEntry => const DeletePlan(
            operation: DeleteOperation.removeEntry,
            metadata: 'delete',
            file: 'keep',
            description: '移除条目：删除元数据，保留文件本体（暂时不想看到这本书）',
          ),
        DeleteOperation.deleteBook => const DeletePlan(
            operation: DeleteOperation.deleteBook,
            metadata: 'delete',
            file: 'trash',
            description: '删除书籍：删除元数据，文件移到 .trash/（彻底删除）',
          ),
        DeleteOperation.deleteLocalOnly => const DeletePlan(
            operation: DeleteOperation.deleteLocalOnly,
            metadata: 'keep',
            file: 'delete',
            nextFileSyncState: SyncState.localOnly,
            description: '仅删除本地：保留元数据，本地文件删除，sync_state.file 改为 local_only（本地空间不足）',
          ),
        DeleteOperation.cancelSync => const DeletePlan(
            operation: DeleteOperation.cancelSync,
            metadata: 'keep',
            file: 'delete',
            description: '取消同步：保留元数据，网盘和本地都删除（只保留书目信息）',
          ),
      };
}

/// Schema 版本兼容性（设计文档 1.9）。
class SchemaCheck {
  const SchemaCheck({required this.declared, required this.implemented, required this.verdict, required this.reason});

  final String declared;
  final String implemented;

  /// `compatible` / `compatible-forward` / `incompatible`。
  final String verdict;
  final String reason;

  bool get isCompatible => verdict != 'incompatible';
}

/// 当前实现的 schema 版本。
const String kSchemaVersion = '1.0';

/// 兼容性检查（与 TypeScript 版 `checkSchemaCompatibility` 逻辑一致）。
SchemaCheck checkSchemaCompatibility(String declared, [String implemented = kSchemaVersion]) {
  final d = _parseVersion(declared);
  final i = _parseVersion(implemented);
  if (d == null || i == null) {
    return SchemaCheck(
      declared: declared,
      implemented: implemented,
      verdict: 'incompatible',
      reason: 'schema_version 不是合法的语义化版本号',
    );
  }
  if (d[0] != i[0]) {
    return SchemaCheck(
      declared: declared,
      implemented: implemented,
      verdict: 'incompatible',
      reason: '主版本不兼容：文档 $declared 与本实现 $implemented',
    );
  }
  if (d[1] > i[1]) {
    return SchemaCheck(
      declared: declared,
      implemented: implemented,
      verdict: 'incompatible',
      reason: '文档次版本 $declared 高于本实现 $implemented，请升级客户端',
    );
  }
  if (d[1] < i[1]) {
    return SchemaCheck(
      declared: declared,
      implemented: implemented,
      verdict: 'compatible-forward',
      reason: '文档次版本 $declared 低于本实现 $implemented，向后兼容，将忽略未知字段',
    );
  }
  return SchemaCheck(declared: declared, implemented: implemented, verdict: 'compatible', reason: 'schema 版本一致');
}

List<int>? _parseVersion(String version) {
  final match = RegExp(r'^(\d+)\.(\d+)(?:\.(\d+))?$').firstMatch(version.trim());
  if (match == null) return null;
  return [int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3) ?? '0')];
}

/// JSON 解析辅助（与 TS 侧一致的宽松解析：结构不符时抛 FormatException）。
Library parseLibrary(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic>) throw const FormatException('library.json 必须是一个 JSON 对象');
  return Library.fromJson(json);
}

String encodeLibrary(Library library) => const JsonEncoder.withIndent('  ').convert(library.toJson());

Manifest parseManifest(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic>) throw const FormatException('manifest.json 必须是一个 JSON 对象');
  return Manifest.fromJson(json);
}

String encodeManifest(Manifest manifest) => const JsonEncoder.withIndent('  ').convert(manifest.toJson());
