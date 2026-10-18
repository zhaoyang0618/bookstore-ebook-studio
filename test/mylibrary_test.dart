/// Dart 侧单元测试：验证数据契约与 TypeScript 实现一致。
///
/// 这些测试读写与 `mylibrary/fixtures/MyLibrary` **同一份数据**，
/// 证明两个软件能操作同一份 MyLibrary（设计文档第四部分「数据互通」）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:ebook_studio/engines/book_engine.dart';
import 'package:ebook_studio/library/catalog.dart';
import 'package:ebook_studio/models/mylibrary_models.dart';
import 'package:ebook_studio/storage/my_library_store.dart';
import 'package:ebook_studio/storage/remote_provider.dart';
import 'package:ebook_studio/storage/sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// 临时目录里的一个 MyLibrary。
Library makeLibrary({
  List<Book> books = const [],
  int version = 1,
  String updatedAt = '2026-10-16T10:30:00Z',
  String updatedBy = 'local',
}) {
  return Library(
    schemaVersion: '1.0',
    version: version,
    updatedAt: updatedAt,
    updatedBy: updatedBy,
    books: books,
    collections: const [],
    tags: const [],
  );
}

Book makeBook({
  String id = 'uuid-1',
  String title = '三体',
  String author = '刘慈欣',
  BookFormat format = BookFormat.epub,
  String relativePath = 'books/三体/三体.epub',
  List<String> tags = const [],
  List<String> collections = const [],
  List<String> linkedWikiPages = const [],
  ReadingPosition? readingPosition,
  BookSyncState? syncState,
  List<BookHolder> heldBy = const [],
  int sizeBytes = 1048576,
  String? fileHash,
  String? recordingsDir,
}) {
  return Book(
    id: id,
    title: title,
    author: author,
    format: format,
    relativePath: relativePath,
    sizeBytes: sizeBytes,
    addedAt: '2026-10-01T00:00:00Z',
    syncState: syncState ?? const BookSyncState(metadata: SyncState.synced, cover: SyncState.synced, notes: SyncState.synced, file: SyncState.localOnly, recordings: SyncState.localOnly),
    heldBy: heldBy,
    readingPosition: readingPosition,
    tags: tags,
    collections: collections,
    linkedWikiPages: linkedWikiPages,
    fileHash: fileHash,
    recordingsDir: recordingsDir ?? 'books/三体/recordings/',
  );
}

void main() {
  group('Schema 兼容性（设计文档 1.9）', () {
    test('相同版本 compatible', () {
      expect(checkSchemaCompatibility('1.0', '1.0').verdict, 'compatible');
    });

    test('主版本不同 incompatible', () {
      expect(checkSchemaCompatibility('2.0', '1.0').verdict, 'incompatible');
    });

    test('文档次版本更高 incompatible', () {
      expect(checkSchemaCompatibility('1.3', '1.0').verdict, 'incompatible');
    });

    test('文档次版本更低 compatible-forward', () {
      expect(checkSchemaCompatibility('1.0', '1.2').verdict, 'compatible-forward');
    });

    test('非法版本号 incompatible', () {
      expect(checkSchemaCompatibility('abc').verdict, 'incompatible');
    });
  });

  group('版本对比（设计文档 1.8.1）', () {
    test('网盘版本更高 → download', () {
      expect(SyncPlan.compare(makeLibrary(version: 1), makeLibrary(version: 2)).action, 'download');
    });

    test('版本一致 → none', () {
      expect(SyncPlan.compare(makeLibrary(version: 7), makeLibrary(version: 7)).action, 'none');
    });

    test('本地版本更高 → upload', () {
      expect(SyncPlan.compare(makeLibrary(version: 9), makeLibrary(version: 3)).action, 'upload');
    });
  });

  group('冲突合并（设计文档 1.8.2）', () {
    test('不同书籍按 book_id 取并集', () {
      final local = makeLibrary(books: [makeBook(id: 'a', title: 'A')]);
      final remote = makeLibrary(books: [makeBook(id: 'b', title: 'B')], version: 5);
      final merged = mergeLibraries(local, remote);
      expect(merged.value.books.map((b) => b.id).toSet(), {'a', 'b'});
      expect(merged.value.version, 5);
      expect(merged.actions.any((action) => action.kind == 'book-added'), isTrue);
    });

    test('tags / collections / linked_wiki_pages 取并集', () {
      final local = makeLibrary(books: [
        makeBook(tags: ['科幻'], collections: ['待读'], linkedWikiPages: ['a'])
      ]);
      final remote = makeLibrary(
        books: [makeBook(tags: ['中文', '科幻'], collections: ['已读'], linkedWikiPages: ['b'])],
        version: 5,
      );
      final book = mergeLibraries(local, remote).value.books.first;
      expect(book.tags.toSet(), {'科幻', '中文'});
      expect(book.collections.toSet(), {'待读', '已读'});
      expect(book.linkedWikiPages.toSet(), {'a', 'b'});
    });

    test('reading_position 按 updated_at 取最新', () {
      final local = makeLibrary(books: [
        makeBook(readingPosition: ReadingPosition(position: 'p-local', percentage: 0.2, updatedAt: '2026-10-16T08:30:00Z', updatedBy: 'local'))
      ]);
      final remote = makeLibrary(
        books: [makeBook(readingPosition: ReadingPosition(position: 'p-remote', percentage: 0.8, updatedAt: '2026-10-16T11:00:00Z', updatedBy: 'remote'))],
        version: 5,
      );
      expect(mergeLibraries(local, remote).value.books.first.readingPosition?.position, 'p-remote');
    });

    test('held_by 取并集并按 last_seen 降序', () {
      final local = makeLibrary(books: [
        makeBook(heldBy: const [
          BookHolder(clientId: 'mac', lastSeen: '2026-10-16T08:30:00Z'),
          BookHolder(clientId: 'ipad', lastSeen: '2026-10-16T11:00:00Z'),
        ])
      ]);
      final remote = makeLibrary(
        books: [makeBook(heldBy: const [BookHolder(clientId: 'win', lastSeen: '2026-10-16T10:30:00Z')])],
        version: 5,
      );
      final holders = mergeLibraries(local, remote).value.books.first.heldBy;
      expect(holders.map((h) => h.clientId).toList(), ['ipad', 'win', 'mac']);
    });

    test('sync_state 五维度各自取更可达的状态', () {
      const local = BookSyncState(metadata: SyncState.synced, cover: SyncState.localOnly, notes: SyncState.synced, file: SyncState.localOnly, recordings: SyncState.missing);
      const remote = BookSyncState(metadata: SyncState.synced, cover: SyncState.synced, notes: SyncState.localOnly, file: SyncState.synced, recordings: SyncState.partial);
      final merged = local.mergeWith(remote);
      expect(merged.metadata, SyncState.synced);
      expect(merged.cover, SyncState.synced);
      expect(merged.notes, SyncState.synced);
      expect(merged.file, SyncState.synced);
      expect(merged.recordings, SyncState.partial);
    });

    test('manual 策略下 file_hash 不一致标记为未解决冲突', () {
      final local = makeLibrary(books: [makeBook(fileHash: 'sha256:aaa')]);
      final remote = makeLibrary(books: [makeBook(fileHash: 'sha256:bbb')], version: 5);
      final merged = mergeLibraries(local, remote, ConflictStrategy.manual);
      expect(merged.hasUnresolvedConflicts, isTrue);
    });
  });

  group('同步请求队列（设计文档 1.8.4）', () {
    test('文件名规范', () {
      expect(syncRequestFileName('uuid-1', 'flutter-ipad'), 'sync-req-uuid-1-flutter-ipad.json');
    });

    test('构造 pending 请求', () {
      final request = createSyncRequest('uuid-1', 'ipad', id: 'sync-req-1');
      expect(request.status, 'pending');
      expect(request.bookId, 'uuid-1');
    });

    test('挑出针对其它客户端的待处理请求', () {
      final request = createSyncRequest('b1', 'ipad', id: 'r1');
      expect(request.isPendingFor('mac'), isTrue);
      expect(request.isPendingFor('ipad'), isFalse);
    });
  });

  group('删除语义（设计文档 1.8.5）', () {
    test('移除条目：删元数据，留文件', () {
      expect(DeletePlan.of(DeleteOperation.removeEntry).metadata, 'delete');
      expect(DeletePlan.of(DeleteOperation.removeEntry).file, 'keep');
    });

    test('删除书籍：文件进 .trash', () {
      expect(DeletePlan.of(DeleteOperation.deleteBook).file, 'trash');
    });

    test('仅删除本地：sync_state.file 改 local_only', () {
      expect(DeletePlan.of(DeleteOperation.deleteLocalOnly).nextFileSyncState, SyncState.localOnly);
    });
  });

  group('Wiki（设计文档 1.6）', () {
    test('slugify 英文与中文', () {
      expect(slugify('Dark Forest'), 'dark-forest');
      expect(slugify('三体人物关系'), '三体人物关系');
      expect(slugify('  --Hello--  '), 'hello');
    });

    test('extractWikiLinks 提取并去重', () {
      expect(extractWikiLinks('[[A]] 和 [[B]] 和 [[A]]'), ['a', 'b']);
    });

    test('extractWikiLinks 支持别名与锚点', () {
      expect(extractWikiLinks('[[叶文洁|文洁]] [[三体#第一章]]'), ['叶文洁', '三体']);
    });

    test('解析文档中的 Wiki 页面', () {
      final content = '---\n'
          'id: uuid-wiki-1\n'
          'slug: san-ti-ren-wu-guan-xi\n'
          'title: 三体人物关系\n'
          'created_at: 2026-10-10T00:00:00Z\n'
          'updated_at: 2026-10-16T00:00:00Z\n'
          'tags: [三体, 人物]\n'
          'source_books: [uuid-1]\n'
          'links:\n'
          '  - dark-forest\n'
          '  - ye-wenjie\n'
          '---\n\n'
          '# 三体人物关系\n\n[[叶文洁]] 是 [[三体]] 中的核心人物。\n';
      final page = parseWikiPage(content, 'san-ti-ren-wu-guan-xi.md');
      expect(page.title, '三体人物关系');
      expect(page.tags, ['三体', '人物']);
      expect(page.sourceBooks, ['uuid-1']);
      expect(page.links, ['dark-forest', 'ye-wenjie']);
      expect(page.wikiLinks, ['叶文洁', '三体']);
      expect(page.allLinks.toSet(), {'dark-forest', 'ye-wenjie', '叶文洁', '三体'});
    });

    test('缺少 frontmatter 报错', () {
      expect(() => parseWikiPage('# 没有 frontmatter', 'x.md'), throwsA(isA<MyLibraryException>()));
    });

    test('序列化往返等价', () {
      final page = createWikiPage(id: 'w', title: '黑暗森林法则', now: '2026-10-16T00:00:00Z');
      final round = parseWikiPage(stringifyWikiPage(page), page.relativePath);
      expect(round.id, page.id);
      expect(round.slug, page.slug);
      expect(round.title, page.title);
      expect(round.body.trim(), page.body.trim());
    });
  });

  group('拉取路径（设计文档 2.5）', () {
    test('同一 WebDAV 账号 → 网盘内复制', () {
      expect(choosePullStrategy(sameProvider: true, providerId: 'webdav', sameAccount: true), PullStrategy.remoteCopy);
    });

    test('百度网盘 → 下载后上传', () {
      expect(choosePullStrategy(sameProvider: true, providerId: 'baidu', sameAccount: true), PullStrategy.downloadThenUpload);
    });
  });

  group('扫描与导入（设计文档 3.4）', () {
    late Directory temp;
    late MyLibraryStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ebook_studio_');
      store = MyLibraryStore('${temp.path}/MyLibrary', clientId: 'test');
      store.init();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('扫描目录找出书籍文件并跳过元数据', () {
      final src = Directory('${temp.path}/src')..createSync(recursive: true);
      File('${src.path}/三体.epub').writeAsStringSync('epub');
      File('${src.path}/人类简史.pdf').writeAsStringSync('pdf');
      File('${src.path}/三体.notes.json').writeAsStringSync('{}');
      File('${src.path}/cover.png').writeAsStringSync('png');
      final result = scanDirectory(src.path);
      expect(result.books.map((b) => b.fileName).toSet(), {'三体.epub', '人类简史.pdf'});
      expect(result.skipped.any((s) => s.reason == '元数据 / 锁文件'), isTrue);
      expect(result.skipped.any((s) => s.reason == '不支持的扩展名'), isTrue);
    });

    test('导入：复制到 books/{title}/ 并登记元数据', () {
      final src = Directory('${temp.path}/src')..createSync(recursive: true);
      File('${src.path}/三体.epub').writeAsStringSync('epub-content');
      final scanned = scanDirectory(src.path).books.first;
      final book = importBookFile(store, scanned, author: '刘慈欣');
      expect(book.relativePath, 'books/三体/三体.epub');
      expect(File('${temp.path}/MyLibrary/books/三体/三体.epub').readAsStringSync(), 'epub-content');
      expect(store.findBook(book.id)?.format, BookFormat.epub);
    });

    test('重复 id 报错', () {
      final book = makeBook();
      store.addBook(book);
      expect(() => store.addBook(book), throwsA(isA<MyLibraryException>()));
    });

    test('删除语义：delete_book 文件移到 .trash', () {
      store.addBook(makeBook());
      final bookFile = File('${temp.path}/MyLibrary/books/三体/三体.epub');
      bookFile.parent.createSync(recursive: true);
      bookFile.writeAsStringSync('x');
      store.deleteBook('uuid-1', DeleteOperation.deleteBook);
      expect(store.readLibrary().books, isEmpty);
      expect(File('${temp.path}/MyLibrary/.trash/books/uuid-1/三体.epub').existsSync(), isTrue);
    });

    test('删除语义：delete_local_only 保留元数据', () {
      store.addBook(makeBook());
      final bookFile = File('${temp.path}/MyLibrary/books/三体/三体.epub');
      bookFile.parent.createSync(recursive: true);
      bookFile.writeAsStringSync('x');
      store.deleteBook('uuid-1', DeleteOperation.deleteLocalOnly);
      final book = store.findBook('uuid-1')!;
      expect(book.syncState.file, SyncState.localOnly);
      expect(File('${temp.path}/MyLibrary/books/三体/三体.epub').existsSync(), isFalse);
    });

    test('笔记边车读写', () {
      final book = store.addBook(makeBook());
      final annotation = Annotation(
        id: 'anno-1',
        type: 'highlight',
        anchor: const {'type': 'epubcfi', 'value': 'epubcfi(/6/4[chap01]!/4/2/2)'},
        text: '给岁月以文明',
        createdAt: '2026-10-15T09:00:00Z',
        updatedAt: '2026-10-16T09:00:00Z',
      );
      store.writeNotes(book, [annotation]);
      final notes = store.readNotes(book);
      expect(notes.annotations, hasLength(1));
      expect(notes.annotations.first.text, '给岁月以文明');
      expect(notes.version, 1);
    });

    test('Wiki 页面读写与索引重建', () {
      store.writeWikiPage(createWikiPage(id: 'w1', title: '黑暗森林法则', tags: ['三体'], sourceBooks: ['uuid-1'], now: '2026-10-16T09:00:00Z'));
      expect(store.readWikiPage('黑暗森林法则')?.title, '黑暗森林法则');
      store.rebuildWikiIndex();
      final index = jsonDecode(File('${temp.path}/MyLibrary/wiki/index.json').readAsStringSync()) as Map<String, dynamic>;
      expect((index['pages'] as List), hasLength(1));
    });

    test('Wiki 图谱出链与反链', () {
      store.writeWikiPage(createWikiPage(id: 'a', title: '叶文洁', now: '2026-10-16T09:00:00Z'));
      final b = createWikiPage(id: 'b', title: '黑暗森林法则', now: '2026-10-16T09:00:00Z');
      store.writeWikiPage(WikiPage(
        id: b.id,
        slug: b.slug,
        title: b.title,
        createdAt: b.createdAt,
        updatedAt: b.updatedAt,
        tags: b.tags,
        sourceBooks: b.sourceBooks,
        links: ['叶文洁'],
        body: b.body,
        relativePath: b.relativePath,
      ));
      final graph = store.buildWikiGraph();
      expect(graph.backlinks['叶文洁'], ['黑暗森林法则']);
    });

    test('录课视频元数据读写', () {
      store.addBook(makeBook());
      store.writeRecording(Recording(
        id: 'rec-1',
        bookId: 'uuid-1',
        title: '黑暗森林法则讲解',
        file: '2026-10-16-黑暗森林解析.mp4',
        durationSeconds: 1250,
        sizeBytes: 158000000,
        createdAt: '2026-10-16T10:30:00Z',
        createdBy: 'flutter-ipad-uuid',
        linkedWikiPages: ['黑暗森林法则'],
      ));
      expect(store.listRecordings(store.findBook('uuid-1')!), hasLength(1));
    });

    test('同步请求队列', () {
      store.writeSyncRequest(createSyncRequest('uuid-1', 'ipad', id: 'sync-req-1'));
      expect(store.listSyncRequests(), hasLength(1));
      store.fulfillSyncRequest('sync-req-1');
      expect(store.listSyncRequests(), isEmpty);
    });

    test('迁移前自动备份（设计文档 1.9）', () {
      final libraryFile = File('${temp.path}/MyLibrary/library.json');
      libraryFile.writeAsStringSync(jsonEncode({...jsonDecode(libraryFile.readAsStringSync()) as Map<String, dynamic>, 'schema_version': '1.1'}));
      final result = store.migrate();
      expect(result.migrated, contains('library.json'));
      expect(result.backedUpTo, isNotNull);
      expect((jsonDecode(libraryFile.readAsStringSync()) as Map<String, dynamic>)['schema_version'], '1.0');
    });

    test('schema 不兼容时读取报错', () {
      final libraryFile = File('${temp.path}/MyLibrary/library.json');
      libraryFile.writeAsStringSync(jsonEncode({...jsonDecode(libraryFile.readAsStringSync()) as Map<String, dynamic>, 'schema_version': '2.0'}));
      expect(() => store.readLibrary(), throwsA(isA<MyLibraryException>()));
    });

    test('manifest touchClient 追加并刷新', () {
      store.touchClient(id: 'flutter-ipad-uuid');
      expect(store.readManifest().clients, hasLength(1));
      store.touchClient(id: 'flutter-ipad-uuid');
      expect(store.readManifest().clients, hasLength(1));
    });
  });

  group('JSON 序列化往返', () {
    test('Library 往返一致', () {
      final library = makeLibrary(books: [
        makeBook(tags: ['科幻'], readingPosition: ReadingPosition(position: 'p', percentage: 0.5, updatedAt: '2026-10-16T10:00:00Z', updatedBy: 'ipad'))
      ]);
      final json = jsonDecode(encodeLibrary(library)) as Map<String, dynamic>;
      final round = Library.fromJson(json);
      expect(round.books.first.title, '三体');
      expect(round.books.first.tags, ['科幻']);
      expect(round.books.first.readingPosition?.percentage, 0.5);
      expect(round.books.first.syncState.file.wire, 'local_only');
    });

    test('Manifest 往返一致', () {
      final manifest = Manifest(
        schemaVersion: '1.0',
        libraryVersion: 42,
        updatedAt: '2026-10-16T10:30:00Z',
        updatedBy: 'mac',
        clients: const [
          ManifestClient(id: 'mac', type: ClientType.dshExtension, platform: ClientPlatform.macos, lastSeen: '2026-10-16T10:30:00Z'),
        ],
      );
      final round = parseManifest(encodeManifest(manifest));
      expect(round.clients.first.type, ClientType.dshExtension);
      expect(round.clients.first.platform, ClientPlatform.macos);
    });
  });

  group('引擎（设计文档 3.3）', () {
    test('工厂按格式返回对应引擎', () {
      expect(createEngine(BookFormat.epub).format, BookFormat.epub);
      expect(createEngine(BookFormat.pdf).format, BookFormat.pdf);
      expect(createEngine(BookFormat.markdown).format, BookFormat.markdown);
      expect(createEngine(BookFormat.txt).format, BookFormat.txt);
    });

    test('TXT 引擎分页', () async {
      final temp = Directory.systemTemp.createTempSync('ebook_txt_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/test.txt');
      file.writeAsStringSync(List.generate(100, (i) => 'line $i').join('\n'));
      final engine = TxtEngine(pageSize: 40);
      final meta = await engine.open(file.path);
      expect(meta.sections, 3);
      expect(engine.currentLines(), hasLength(40));
      engine.nextPage();
      expect(engine.getCurrentPosition().position, '40');
    });

    test('Markdown 引擎提取目录', () async {
      final temp = Directory.systemTemp.createTempSync('ebook_md_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/test.md');
      file.writeAsStringSync('# 标题一\n\n正文\n\n## 标题二\n');
      final engine = MarkdownEngine();
      await engine.open(file.path);
      final toc = await engine.getToc();
      expect(toc.map((item) => item.title), ['标题一', '标题二']);
    });

    test('边车文件路径推导', () {
      expect(notesPathFor('/lib/books/三体/三体.epub'), '/lib/books/三体/三体.notes.json');
      expect(notesPathFor('/lib/a.md'), '/lib/a.notes.json');
    });
  });

  group('跨端数据互通（设计文档 4.2）', () {
    late Directory temp;
    late MyLibraryStore macStore;
    late MyLibraryStore ipadStore;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ebook_cross_');
      macStore = MyLibraryStore('${temp.path}/MyLibrary', clientId: 'dsh-macos-uuid');
      ipadStore = MyLibraryStore('${temp.path}/MyLibrary', clientId: 'flutter-ipad-uuid');
      macStore.init();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('Mac 导入的书，iPad 图书馆可见并更新阅读位置', () {
      macStore.addBook(makeBook(id: 'uuid-1', title: '三体'));
      expect(ipadStore.findBook('uuid-1')?.title, '三体');

      ipadStore.updateBook('uuid-1', (current) => Book(
            id: current.id,
            title: current.title,
            author: current.author,
            format: current.format,
            relativePath: current.relativePath,
            sizeBytes: current.sizeBytes,
            addedAt: current.addedAt,
            syncState: current.syncState,
            heldBy: [...current.heldBy, const BookHolder(clientId: 'flutter-ipad-uuid', lastSeen: '2026-10-16T11:00:00Z')],
            readingPosition: const ReadingPosition(position: 'epubcfi(/6/4[chap03])', percentage: 0.62, updatedAt: '2026-10-16T11:00:00Z', updatedBy: 'flutter-ipad-uuid'),
          ));

      // Mac 端重新打开，看到 iPad 写的进度
      expect(macStore.findBook('uuid-1')?.readingPosition?.percentage, 0.62);
      expect(macStore.findBook('uuid-1')?.heldBy.map((h) => h.clientId).toSet(), {'flutter-ipad-uuid'});
    });

    test('iPad 写 Wiki，Mac 端可见', () {
      ipadStore.writeWikiPage(createWikiPage(id: 'w1', title: '黑暗森林法则', sourceBooks: ['uuid-1'], now: '2026-10-16T09:00:00Z'));
      expect(macStore.readWikiPage('黑暗森林法则')?.sourceBooks, ['uuid-1']);
    });

    test('两端 library.json 合并', () {
      macStore.addBook(makeBook(id: 'a', title: '三体'));
      ipadStore.addBook(makeBook(id: 'b', title: '人类简史', format: BookFormat.pdf, relativePath: 'books/人类简史/人类简史.pdf'));
      final merged = mergeLibraries(macStore.readLibrary(), ipadStore.readLibrary());
      expect(merged.value.books.map((b) => b.id).toSet(), {'a', 'b'});
      expect(merged.hasUnresolvedConflicts, isFalse);
    });
  });
}
