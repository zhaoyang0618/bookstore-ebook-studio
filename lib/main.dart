/// ebook_studio 入口（设计文档 3.7 目录结构中的 lib/main.dart）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'pdf/pdf_ink_export.dart';
import 'storage/notes_location.dart';
import 'util/app_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端初始化窗口管理（全屏切换用，见 lib/ui/fullscreen.dart）
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();
  }

  // 配置批注边车的「退回目录」。
  //
  // 背景：设计文档 1.5 要求边车就在书旁边（随书同步）。但 macOS 沙箱
  // 只授予用户选中的**那一个文件**的读写权限，不包括它所在目录，
  // 因此「直接打开一本书」选到的散装文件无法在旁边创建 .notes.json。
  // 这里准备一个应用内部目录作为兜底，保证批注不会丢。
  //
  // 若用户打开的是目录（如 MyLibrary 根目录），沙箱授予整个目录的
  // 权限，边车仍会写在书旁边 —— 由 notes_location 的可写性探测决定。
  try {
    final docs = await getApplicationDocumentsDirectory();
    await AppLog.init();
    notesFallbackDir = p.join(docs.path, 'annotations');
    // 写回原生 PDF 注释前会先把原文件备份到这里
    pdfBackupDir = p.join(docs.path, 'pdf-backups');
  } catch (error, stack) {
    // 拿不到文档目录不应该导致应用起不来：此时退回目录为空，
    // 写边车失败会照常报错，用户能看到真实原因
    debugPrint('无法准备批注退回目录：$error\n$stack');
  }

  runApp(const ProviderScope(child: EbookStudioApp()));
}
