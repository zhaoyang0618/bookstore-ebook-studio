/// 录课视频的落盘逻辑（设计文档 1.7）。
///
/// 职责：原生层只负责「把视频录到一个临时位置」，本模块负责
/// 把视频挪到最终位置、写同名 JSON 元数据、列出与删除。
///
/// 落点规则：
/// - 图书馆内的书：`MyLibrary/books/{书名}/recordings/`（随图书馆同步，设计文档 1.2）
/// - 独立模式：应用文档目录 `recordings/`
///
/// 纯 dart:io 实现，无 Flutter 依赖，可单测。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/mylibrary_models.dart';
import '../../storage/my_library_store.dart';

/// 视频文件名：`2026-10-24-143005.mp4`。
///
/// 与原生层（ReplayKit / MediaProjection / AVCapture）的命名保持一致，
/// 各端都不含中文与空格，跨平台同步安全。
String recordingFileName(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}-${two(time.hour)}${two(time.minute)}${two(time.second)}.mp4';
}

/// 由视频文件名推出同名元数据文件名。
String metadataFileNameFor(String videoFileName) =>
    videoFileName.replaceAll(RegExp(r'\.[^.]+$'), '.json');

/// 一本书的录课视频目录（相对 MyLibrary 根）。
///
/// 书籍资产都在书文件所在目录（设计文档 1.2）：
/// `books/三体/三体.epub` → `books/三体/recordings`。
String recordingsDirOf(Book book) {
  final bookDir = book.relativePath.replaceAll(RegExp(r'/[^/]*$'), '');
  return p.posix.join(bookDir, MyLibraryLayout.recordingsDirname);
}

/// 构造一条录课元数据（字段与设计文档 1.7 一致）。
Recording buildRecording({
  required String videoFileName,
  required int durationSeconds,
  required int sizeBytes,
  String? bookId,
  String? title,
  String? createdBy = 'flutter-app-client',
  String? createdAt,
  String? positionAtStart,
  String? positionAtEnd,
}) {
  final now = createdAt ?? DateTime.now().toUtc().toIso8601String();
  return Recording(
    id: 'rec-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
    bookId: bookId ?? '',
    title: title ?? _defaultTitle(DateTime.now()),
    file: videoFileName,
    durationSeconds: durationSeconds,
    sizeBytes: sizeBytes,
    createdAt: now,
    createdBy: createdBy ?? 'flutter-app-client',
    linkedWikiPages: const [],
    positionAtStart: positionAtStart,
    positionAtEnd: positionAtEnd,
  );
}

String _defaultTitle(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '录课 ${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

/// 一个目录下的录课视频仓库（元数据 JSON 与视频同名同目录）。
///
/// [dir] 为空字符串或不存在时表现为空仓库（不抛错 —— 目录还没建立
/// 只说明还没录过）。
class RecordingRepository {
  RecordingRepository(this.dir);

  /// 视频与元数据所在目录。
  final String dir;

  List<Recording> list() {
    if (dir.isEmpty) return const [];
    final directory = Directory(dir);
    if (!directory.existsSync()) return const [];
    final recordings = <Recording>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.json') || name == 'upload.json') continue;
      try {
        final json = jsonDecode(entity.readAsStringSync());
        if (json is! Map<String, dynamic>) continue;
        recordings.add(Recording.fromJson(json));
      } on FormatException {
        // 单个坏文件不拖垮整个列表；保留文件等用户手工处理
        continue;
      }
    }
    // 新的在前（created_at 降序）
    recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return recordings;
  }

  /// 把已录好的视频与元数据写入仓库（视频从 [sourcePath] 移入）。
  ///
  /// 返回最终的视频路径。同名的旧文件被覆盖。
  String importVideo({
    required String sourcePath,
    required Recording recording,
  }) {
    Directory(dir).createSync(recursive: true);
    final videoPath = p.join(dir, recording.file);
    final source = File(sourcePath);
    if (p.equals(source.path, videoPath)) {
      // 已在目标目录（原生层直接录到这里），不移动
    } else if (source.existsSync()) {
      // 先复制再删源：跨卷 rename 会失败（macOS 容器目录 ↔ MyLibrary）
      source.copySync(videoPath);
      source.deleteSync();
    }
    final jsonName = metadataFileNameFor(recording.file);
    File(p.join(dir, jsonName)).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(recording.toJson())}\n',
    );
    return videoPath;
  }

  /// 视频文件的完整路径（文件可能不存在 —— 元数据在、视频被用户删掉
  /// 是设计文档 1.1 原则四的「明确状态」，不视为错误）。
  String videoPathOf(Recording recording) => p.join(dir, recording.file);

  /// 删除一条录课：视频与元数据都删（存在才删）。
  void delete(Recording recording) {
    for (final name in [recording.file, metadataFileNameFor(recording.file)]) {
      final file = File(p.join(dir, name));
      if (file.existsSync()) file.deleteSync();
    }
  }
}
