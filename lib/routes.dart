/// 应用路由状态（独立文件，避免 app.dart 与各页面互相 import 形成环）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 顶层路由。
enum AppRoute { library, reader, notes, record, translate }

/// 当前路由。
final appRouteProvider = StateProvider<AppRoute>((ref) => AppRoute.library);
