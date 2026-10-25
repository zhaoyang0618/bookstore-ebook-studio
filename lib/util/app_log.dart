/// 轻量文件日志（诊断手势 / 录制 / 平台事件路由问题用）。
///
/// - 位置：应用文档目录 `logs/app.log`（macOS 沙箱内为容器的 Documents），
///   超过 2MB 自动轮转为 `app.1.log`（保留上一份）。
/// - [log] 同步追加（量小、频率高的事件也不会丢），同时走 debugPrint。
/// - UI 里用 [path] / [readTail] / [clear] 做「诊断日志」查看器。
///
/// @module ebook-studio/util/app_log
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppLog {
  AppLog._();

  static File? _file;
  static const int _maxBytes = 2 * 1024 * 1024;

  static Future<void> init() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'logs'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'app.log'));
      if (await file.exists() && await file.length() > _maxBytes) {
        final previous = p.join(dir.path, 'app.1.log');
        final old = File(previous);
        if (await old.exists()) await old.delete();
        await file.rename(previous);
      }
      _file = file;
      log('app', '==== session start（v=log 版本占位）====');
      log('app', 'log file: ${file.path}');
    } catch (error) {
      _file = null;
      debugPrint('AppLog 初始化失败：$error');
    }
  }

  /// 日志文件完整路径（未初始化成功时为 null）。
  static String? get path => _file?.path;

  static void log(String tag, Object message) {
    final line = '${DateTime.now().toIso8601String()} [$tag] $message';
    debugPrint(line);
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // 日志写失败不影响功能
    }
  }

  /// 读取末尾 [lines] 行（文件不存在返回 null）。
  static Future<String?> readTail([int lines = 400]) async {
    final file = _file;
    if (file == null || !await file.exists()) return null;
    try {
      final content = await file.readAsString();
      final parts = content.split('\n');
      return parts.skip(parts.length - lines - 1).join('\n');
    } catch (error) {
      return '读取日志失败：$error';
    }
  }

  static Future<void> clear() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString('${DateTime.now().toIso8601String()} [app] ==== 日志已清空 ====\n');
    } catch (_) {}
  }
}
