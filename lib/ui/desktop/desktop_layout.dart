/// 桌面布局（设计文档 3.7 `ui/desktop`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes.dart';

/// 桌面布局：左侧导航栏 + 右侧内容区。
class DesktopLayout extends ConsumerWidget {
  const DesktopLayout({required this.route, required this.body, super.key});

  final AppRoute route;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: route.index,
            onDestinationSelected: (index) => ref.read(appRouteProvider.notifier).state = AppRoute.values[index],
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.library_books_outlined), selectedIcon: Icon(Icons.library_books), label: Text('图书馆')),
              NavigationRailDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: Text('阅读器')),
              NavigationRailDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: Text('录课')),
              NavigationRailDestination(icon: Icon(Icons.translate_outlined), selectedIcon: Icon(Icons.translate), label: Text('翻译')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}
