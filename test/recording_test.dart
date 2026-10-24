/// 录课落盘逻辑测试：文件命名、元数据构造、仓库（导入/列出/删除）。
library;

import 'dart:io';

import 'package:ebook_studio/features/recorder/recording_catalog.dart';
import 'package:ebook_studio/models/mylibrary_models.dart';
import 'package:ebook_studio/storage/my_library_store.dart';
import 'package:flutter_test/flutter_test.dart';

Book makeBook({
  String id = 'uuid-1',
  String relativePath = 'books/三体/三体.epub',
}) {
  return Book(
    id: id,
    title: '三体',
    author: '刘慈欣',
    format: BookFormat.epub,
    relativePath: relativePath,
    sizeBytes: 1024,
    addedAt: '2026-10-01T00:00:00Z',
    syncState: const BookSyncState(
      metadata: SyncState.synced,
      cover: SyncState.synced,
      notes: SyncState.synced,
      file: SyncState.localOnly,
      recordings: SyncState.localOnly,
    ),
    heldBy: const [],
  );
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('recording-test');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('命名规则', () {
    test('视频文件名 yyyy-MM-dd-HHmmss.mp4', () {
      expect(
        recordingFileName(DateTime(2026, 10, 24, 9, 5, 3)),
        '2026-10-24-090503.mp4',
      );
    });

    test('元数据文件名与视频同名（.json）', () {
      expect(metadataFileNameFor('2026-10-24-090503.mp4'), '2026-10-24-090503.json');
    });

    test('书的录课目录 = 书文件所在目录 / recordings', () {
      expect(recordingsDirOf(makeBook()), 'books/三体/recordings');
      // 深层路径也成立
      expect(
        recordingsDirOf(makeBook(relativePath: 'books/a/b/c.pdf')),
        'books/a/b/recordings',
      );
    });
  });

  group('元数据构造（设计文档 1.7）', () {
    test('必填字段齐全，id 可解析', () {
      final recording = buildRecording(
        videoFileName: '2026-10-24-090503.mp4',
        durationSeconds: 1250,
        sizeBytes: 158000000,
        bookId: 'uuid-1',
        title: '黑暗森林法则讲解',
        positionAtStart: 'epubcfi(/6/4[chap05]!/4/2/2)',
      );
      expect(recording.id, startsWith('rec-'));
      expect(recording.bookId, 'uuid-1');
      expect(recording.file, '2026-10-24-090503.mp4');
      expect(recording.durationSeconds, 1250);
      expect(recording.sizeBytes, 158000000);
      expect(recording.createdBy, 'flutter-app-client');
      expect(recording.positionAtStart, 'epubcfi(/6/4[chap05]!/4/2/2)');
      expect(recording.positionAtEnd, isNull);
      expect(recording.linkedWikiPages, isEmpty);
    });

    test('独立模式（无书）：book_id 为空字符串，标题走默认', () {
      final recording = buildRecording(
        videoFileName: 'a.mp4',
        durationSeconds: 60,
        sizeBytes: 1,
      );
      expect(recording.bookId, '');
      expect(recording.title, startsWith('录课 '));
    });

    test('JSON 往返', () {
      final recording = buildRecording(
        videoFileName: 'a.mp4',
        durationSeconds: 60,
        sizeBytes: 1,
        bookId: 'uuid-1',
      );
      final restored = Recording.fromJson(recording.toJson());
      expect(restored.id, recording.id);
      expect(restored.durationSeconds, 60);
      expect(restored.file, 'a.mp4');
      expect(restored.linkedWikiPages, isEmpty);
    });
  });

  group('RecordingRepository', () {
    test('空目录 / 不存在的目录 → 空列表', () {
      expect(RecordingRepository('').list(), isEmpty);
      expect(RecordingRepository('${temp.path}/none').list(), isEmpty);
    });

    test('importVideo 移动视频并写元数据 JSON', () {
      final source = File('${temp.path}/source.mp4')..writeAsStringSync('fake-video');
      final repository = RecordingRepository('${temp.path}/books/x/recordings');
      final recording = buildRecording(
        videoFileName: '2026-10-24-090503.mp4',
        durationSeconds: 10,
        sizeBytes: source.lengthSync(),
        bookId: 'uuid-1',
      );

      final videoPath = repository.importVideo(sourcePath: source.path, recording: recording);

      expect(videoPath, endsWith('recordings/2026-10-24-090503.mp4'));
      expect(File(videoPath).existsSync(), isTrue);
      expect(source.existsSync(), isFalse, reason: '导入后源文件应被移走');
      expect(File(videoPath).readAsStringSync(), 'fake-video');

      final listed = repository.list();
      expect(listed, hasLength(1));
      expect(listed.first.file, '2026-10-24-090503.mp4');
      expect(listed.first.durationSeconds, 10);
    });

    test('list 按创建时间降序（新的在前）', () {
      final repository = RecordingRepository(temp.path);
      final old = buildRecording(
        videoFileName: 'a.mp4',
        durationSeconds: 1,
        sizeBytes: 1,
        createdAt: '2026-10-01T00:00:00Z',
      );
      final newOne = buildRecording(
        videoFileName: 'b.mp4',
        durationSeconds: 2,
        sizeBytes: 2,
        createdAt: '2026-10-24T00:00:00Z',
      );
      repository.importVideo(sourcePath: _makeFakeVideo(temp, 'a.mp4'), recording: old);
      repository.importVideo(sourcePath: _makeFakeVideo(temp, 'b.mp4'), recording: newOne);

      expect(repository.list().map((r) => r.file).toList(), ['b.mp4', 'a.mp4']);
    });

    test('delete 连视频与元数据一起删', () {
      final repository = RecordingRepository(temp.path);
      final recording = buildRecording(videoFileName: 'a.mp4', durationSeconds: 1, sizeBytes: 1);
      final videoPath = repository.importVideo(
        sourcePath: _makeFakeVideo(temp, 'a.mp4'),
        recording: recording,
      );
      expect(File(videoPath).existsSync(), isTrue);

      repository.delete(recording);
      expect(File(videoPath).existsSync(), isFalse);
      expect(repository.list(), isEmpty);
    });

    test('videoPathOf 不要求文件存在（悬空引用是明确状态）', () {
      final repository = RecordingRepository(temp.path);
      final recording = buildRecording(videoFileName: 'missing.mp4', durationSeconds: 1, sizeBytes: 1);
      expect(repository.videoPathOf(recording), endsWith('missing.mp4'));
      expect(File(repository.videoPathOf(recording)).existsSync(), isFalse);
    });

    test('损坏的元数据文件被跳过', () {
      final repository = RecordingRepository(temp.path);
      File('${temp.path}/bad.json').writeAsStringSync('not json at all');
      expect(repository.list(), isEmpty);
    });
  });
}

String _makeFakeVideo(Directory dir, String name) {
  final file = File('${dir.path}/$name')..writeAsStringSync('fake-$name');
  return file.path;
}
