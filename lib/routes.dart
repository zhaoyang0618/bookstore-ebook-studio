/// 应用路由状态（独立文件，避免 app.dart 与各页面互相 import 形成环）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 顶层路由。
///
/// 录课不再是独立页面：它是阅读器与笔记编辑器的子功能
/// （见 features/recorder/recording_panel.dart）。
enum AppRoute { library, reader, notes, translate }

/// 当前路由。
final appRouteProvider = StateProvider<AppRoute>((ref) => AppRoute.library);
