/// 平板布局（设计文档 3.7 `ui/tablet`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes.dart';

/// 平板布局：底部导航栏 + 全屏内容区（触控友好，设计文档 3.5 平板端手势）。
class TabletLayout extends ConsumerWidget {
  const TabletLayout({required this.route, required this.body, super.key});

  final AppRoute route;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: route.index,
        onDestinationSelected: (index) => ref.read(appRouteProvider.notifier).state = AppRoute.values[index],
        destinations: const [
          NavigationDestination(icon: Icon(Icons.library_books_outlined), selectedIcon: Icon(Icons.library_books), label: '图书馆'),
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: '阅读'),
          NavigationDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: '录课'),
          NavigationDestination(icon: Icon(Icons.translate_outlined), selectedIcon: Icon(Icons.translate), label: '翻译'),
        ],
      ),
    );
  }
}
