/// 批注边车文件的位置解析。
///
/// ## 为什么需要「退回」
///
/// 设计文档 1.5 规定边车就在书旁边：`books/{title}/{title}.notes.json`，
/// 这样批注跟书一起被同步、一起被带走。
///
/// 但 macOS 的 App Sandbox 有个限制：
/// `com.apple.security.files.user-selected.read-write` 只授予
/// **用户通过打开面板选中的那一个文件**的读写权限，
/// 不包括它所在的目录。所以当用户用「直接打开一本书」选了一个
/// 散落在任意位置的 PDF 时，我们**无权在它旁边创建 `.notes.json`**，
/// 写盘会抛 `Cannot open file`。
///
/// 反过来，如果用户选的是一个**目录**（例如 MyLibrary 根目录），
/// 沙箱授予的就是整个目录的访问权，边车放在书旁边完全没问题。
///
/// 因此这里的策略是：**探测书所在目录是否真的可写**，
/// 可写就用书旁边（符合设计文档），不可写就退回应用容器内的
/// `annotations/` 目录（保证功能可用），并把原因告诉用户。
///
/// @module ebook-studio/storage/notes_location
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 退回目录（应用容器内）。应用启动时设置。
///
/// 为空时表示不启用退回 —— 此时写入失败会直接抛错，
/// 便于测试与早期开发阶段暴露问题。
String? notesFallbackDir;

/// 边车文件位置。
class NotesLocation {
  const NotesLocation({
    required this.path,
    required this.besideBook,
    this.reason,
  });

  /// 边车文件的绝对路径。
  final String path;

  /// 是否就在书旁边（设计文档 1.5 的目标形态，随书同步）。
  final bool besideBook;

  /// 退回的原因（仅 [besideBook] 为 false 时有值）。
  final String? reason;

  @override
  String toString() => 'NotesLocation($path, besideBook: $besideBook)';
}

/// 解析结果缓存：同一个书路径只需探测一次。
final Map<String, NotesLocation> _cache = {};

/// 清空缓存（测试用）。
void resetNotesLocationCache() => _cache.clear();

/// 解析某本书的边车位置。
///
/// [probe] 可注入自定义的可写性探测（测试用）。
NotesLocation resolveNotesLocation(
  String bookPath, {
  bool Function(String dir)? probe,
}) {
  final cached = _cache[bookPath];
  if (cached != null) return cached;

  final beside = notesPathFor(bookPath);
  final dir = p.dirname(beside);
  final canWrite = (probe ?? isDirectoryWritable)(dir);

  final location = canWrite
      ? NotesLocation(path: beside, besideBook: true)
      : _fallback(bookPath);

  _cache[bookPath] = location;
  return location;
}

/// 书的边车路径（设计文档 1.5）：与书同目录、同名、`.notes.json` 后缀。
String notesPathFor(String bookPath) {
  final dir = p.dirname(bookPath);
  final name = p.basenameWithoutExtension(bookPath);
  return p.join(dir, '$name.notes.json');
}

/// 目录是否可写（真实探测：写一个临时文件再删掉）。
///
/// 不用 `Directory.statSync().mode` 判断权限位 —— 沙箱拦截发生在
/// 系统调用层，权限位看起来是可写的，真正写才会失败。
bool isDirectoryWritable(String dir) {
  try {
    final target = Directory(dir);
    if (!target.existsSync()) {
      // 目录不存在：尝试创建（库内首次导入的场景）
      target.createSync(recursive: true);
    }
    final probe = File(p.join(dir, '.ebook-studio-probe'));
    probe.writeAsStringSync('probe', flush: true);
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  } on OSError {
    return false;
  }
}

NotesLocation _fallback(String bookPath) {
  final base = notesFallbackDir;
  if (base == null) {
    // 没配置退回目录：仍然返回书旁边的路径，
    // 让调用方拿到真实错误（早期开发阶段更容易发现问题）
    return NotesLocation(path: notesPathFor(bookPath), besideBook: true);
  }
  return NotesLocation(
    path: p.join(base, '${stableKeyFor(bookPath)}.notes.json'),
    besideBook: false,
    reason: '无法在书的目录下创建批注文件（沙箱限制：只授权了该文件本身）。'
        '批注已改为保存在应用内部目录，不会随书一起同步。',
  );
}

/// 由书籍绝对路径生成稳定且可读的文件名。
///
/// 保留书名便于人工识别，后缀接路径哈希避免重名冲突。
String stableKeyFor(String bookPath) {
  final digest = sha1.convert(utf8.encode(bookPath)).toString();
  final base = p.basenameWithoutExtension(bookPath);
  // 只保留字母、数字、下划线、连字符与中文
  final safe = base.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_');
  final clipped = safe.length > 40 ? safe.substring(0, 40) : safe;
  return '$clipped-${digest.substring(0, 12)}';
}
