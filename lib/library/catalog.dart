/// 本地导入：扫描目录、提取元数据、复制到 `books/{书名}/`（设计文档 3.4）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/mylibrary_models.dart';
import '../storage/my_library_store.dart';

/// 支持的书籍扩展名 → 格式。
const Map<String, BookFormat> _scannable = {
  '.epub': BookFormat.epub,
  '.pdf': BookFormat.pdf,
  '.md': BookFormat.markdown,
  '.markdown': BookFormat.markdown,
  '.txt': BookFormat.txt,
};

/// 扫描到的一个候选书籍文件。
class ScannedBookFile {
  const ScannedBookFile({required this.absolutePath, required this.fileName, required this.title, required this.format, required this.sizeBytes});

  final String absolutePath;
  final String fileName;
  final String title;
  final BookFormat format;
  final int sizeBytes;
}

/// 扫描结果。
class ScanResult {
  const ScanResult({required this.books, required this.skipped});

  final List<ScannedBookFile> books;
  final List<({String path, String reason})> skipped;
}

/// 扫描一个目录树，找出可作为书籍导入的文件。
///
/// 跳过规则：
/// - 边车文件（`.notes.json`）、锁文件（`.lock.json`）
/// - 分片上传临时目录（`.parts/`）
/// - 隐藏文件
ScanResult scanDirectory(String root) {
  final books = <ScannedBookFile>[];
  final skipped = <({String path, String reason})>[];

  void walk(String dir) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return;
    for (final entity in directory.listSync()) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) {
        skipped.add((path: entity.path, reason: '隐藏文件或目录'));
        continue;
      }
      if (entity is Directory) {
        if (name.endsWith('.parts')) {
          skipped.add((path: entity.path, reason: '分片上传临时目录'));
          continue;
        }
        walk(entity.path);
        continue;
      }
      if (entity is! File) continue;
      if (name.endsWith('.notes.json') || name.endsWith('.lock.json')) {
        skipped.add((path: entity.path, reason: '元数据 / 锁文件'));
        continue;
      }
      final ext = p.extension(name).toLowerCase();
      final format = _scannable[ext];
      if (format == null) {
        skipped.add((path: entity.path, reason: '不支持的扩展名'));
        continue;
      }
      books.add(ScannedBookFile(
        absolutePath: entity.path,
        fileName: name,
        title: p.basenameWithoutExtension(name),
        format: format,
        sizeBytes: entity.lengthSync(),
      ));
    }
  }

  walk(root);
  return ScanResult(books: books, skipped: skipped);
}

/// 导入一个候选文件：复制到 `books/{title}/` 并在 library.json 中登记。
///
/// 返回新建的 [Book]；id 已存在时抛 [MyLibraryException]。
Book importBookFile(MyLibraryStore store, ScannedBookFile scanned, {String? author, String? id}) {
  final bookId = id ?? 'book-${scanned.title}';
  final book = Book.fromFile(
    id: bookId,
    title: scanned.title,
    author: author ?? '未知作者',
    relativePath: '${MyLibraryLayout.booksDir}/${scanned.title}/${scanned.fileName}',
    sizeBytes: scanned.sizeBytes,
    format: scanned.format,
  );
  final target = File(store.layout.absolute(book.relativePath));
  target.parent.createSync(recursive: true);
  File(scanned.absolutePath).copySync(target.path);
  Directory(store.layout.absolute('${MyLibraryLayout.booksDir}/${scanned.title}/${MyLibraryLayout.recordingsDirname}')).createSync(recursive: true);
  return store.addBook(book);
}

/// 图书检索（设计文档 3.4 `library/search.dart`）。
class LibrarySearch {
  const LibrarySearch(this.store);

  final MyLibraryStore store;

  /// 按关键词搜索。
  List<Book> byKeyword(String query) => store.searchBooks(query);

  /// 按标签筛选。
  List<Book> byTag(String tag) => store.readLibrary().books.where((book) => book.tags.contains(tag)).toList();

  /// 按收藏夹筛选。
  List<Book> byCollection(String collection) =>
      store.readLibrary().books.where((book) => book.collections.contains(collection)).toList();

  /// 按格式筛选。
  List<Book> byFormat(BookFormat format) => store.readLibrary().books.where((book) => book.format == format).toList();

  /// 未读完的书（进度 < 100%）。
  List<Book> inProgress() => store.readLibrary().books.where((book) => book.percentage > 0 && book.percentage < 1).toList();
}
