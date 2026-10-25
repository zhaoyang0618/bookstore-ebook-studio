/// 全屏切换（设计文档 3.7 的外壳能力）。
///
/// - 桌面（macOS / Windows / Linux）：`window_manager.setFullScreen`，
///   桌面布局的导航栏底部有按钮，**F11** 也可以切换。
/// - 平板（iPad / Android）：`SystemChrome` 沉浸式（隐藏系统栏，
///   sticky 模式下滑可临时唤出），入口在各个页面的 AppBar 上。
///
/// @module ebook-studio/ui/fullscreen
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// 当前是否处于全屏。
final fullscreenProvider = StateProvider<bool>((ref) => false);

bool _isDesktop() =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 切换全屏。
Future<void> toggleFullscreen(WidgetRef ref) async {
  final next = !ref.read(fullscreenProvider);
  try {
    if (_isDesktop()) {
      await windowManager.setFullScreen(next);
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
    ref.read(fullscreenProvider.notifier).state = next;
  } catch (error) {
    debugPrint('切换全屏失败：$error');
  }
}

/// AppBar 用的全屏按钮。
///
/// 桌面端不显示（桌面布局的导航栏底部已有按钮 + F11 快捷键），
/// 避免同一个控制出现两份。
class FullscreenAppBarButton extends ConsumerWidget {
  const FullscreenAppBarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_isDesktop()) return const SizedBox.shrink();
    final fullscreen = ref.watch(fullscreenProvider);
    return IconButton(
      tooltip: fullscreen ? '退出全屏' : '进入全屏',
      icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
      onPressed: () => toggleFullscreen(ref),
    );
  }
}
