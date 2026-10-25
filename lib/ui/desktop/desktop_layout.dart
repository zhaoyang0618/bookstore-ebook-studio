/// 桌面布局（设计文档 3.7 `ui/desktop`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes.dart';
import '../fullscreen.dart';

/// 桌面布局：左侧导航栏 + 右侧内容区。
///
/// 全屏：导航栏底部的按钮，或 **F11**。
class DesktopLayout extends ConsumerWidget {
  const DesktopLayout({required this.route, required this.body, super.key});

  final AppRoute route;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fullscreen = ref.watch(fullscreenProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f11): () => toggleFullscreen(ref),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: route.index,
                onDestinationSelected: (index) =>
                    ref.read(appRouteProvider.notifier).state = AppRoute.values[index],
                labelType: NavigationRailLabelType.all,
                trailing: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: IconButton(
                    tooltip: fullscreen ? '退出全屏（F11）' : '进入全屏（F11）',
                    icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                    onPressed: () => toggleFullscreen(ref),
                  ),
                ),
                destinations: const [
                  NavigationRailDestination(icon: Icon(Icons.library_books_outlined), selectedIcon: Icon(Icons.library_books), label: Text('图书馆')),
                  NavigationRailDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: Text('阅读器')),
                  NavigationRailDestination(icon: Icon(Icons.draw_outlined), selectedIcon: Icon(Icons.draw), label: Text('笔记')),
                  NavigationRailDestination(icon: Icon(Icons.translate_outlined), selectedIcon: Icon(Icons.translate), label: Text('翻译')),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
