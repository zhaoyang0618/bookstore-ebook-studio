/// 应用外壳：按平台选择桌面 / 平板布局（设计文档 3.7 `ui/desktop` 与 `ui/tablet`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_page.dart';
import '../reader/reader_page.dart';
import '../features/recorder/record_page.dart';
import '../features/translation/translate_page.dart';
import 'routes.dart';
import 'ui/desktop/desktop_layout.dart';
import 'ui/tablet/tablet_layout.dart';

/// 应用根组件。
class EbookStudioApp extends ConsumerWidget {
  const EbookStudioApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref.watch(appRouteProvider);
    return MaterialApp(
      title: 'ebook studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: _ResponsiveShell(route: route),
    );
  }
}

/// 按平台宽度在桌面布局与平板布局间切换。
class _ResponsiveShell extends StatelessWidget {
  const _ResponsiveShell({required this.route});

  final AppRoute route;

  /// 超过这个宽度视为桌面 / 大屏平板。
  static const double _desktopBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final body = switch (route) {
      AppRoute.library => const LibraryPage(),
      AppRoute.reader => const ReaderPage(),
      AppRoute.record => const RecordPage(),
      AppRoute.translate => const TranslatePage(),
    };
    return width >= _desktopBreakpoint ? DesktopLayout(route: route, body: body) : TabletLayout(route: route, body: body);
  }
}
