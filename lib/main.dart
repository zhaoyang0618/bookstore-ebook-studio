/// ebook_studio 入口（设计文档 3.7 目录结构中的 lib/main.dart）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: EbookStudioApp()));
}
