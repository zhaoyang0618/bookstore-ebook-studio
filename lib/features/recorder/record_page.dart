/// 录课（设计文档 3.5）。
///
/// 桌面端：`desktop_screen_recorder` 包，H.264 编码输出 MP4。
/// 平板端：iPad 用 ReplayKit（`ios/Runner/ReplayKitBridge.swift`），
/// Android 用 MediaProjection（`android/.../MediaProjectionBridge.kt`），
/// 都通过 Platform Channel 调用。
///
/// 手写标注层用 `CustomPainter` 绘制笔迹，以矢量形式存储。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/library_page.dart';

/// Platform Channel 名称。
const String _recorderChannel = 'ebook_studio/recorder';

/// 录制状态。
enum RecorderState { idle, recording, paused, stopped }

/// 录制控制器状态。
final recorderStateProvider = StateProvider<RecorderState>((ref) => RecorderState.idle);

/// 已录制的秒数。
final recordingSecondsProvider = StateProvider<int>((ref) => 0);

/// 录课界面。
class RecordPage extends ConsumerStatefulWidget {
  const RecordPage({super.key});

  @override
  ConsumerState<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends ConsumerState<RecordPage> {
  static const MethodChannel _channel = MethodChannel(_recorderChannel);
  Timer? _timer;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 开始录制（桌面端与平板端走不同的原生实现）。
  Future<void> _start() async {
    setState(() => _error = null);
    try {
      await _channel.invokeMethod('startRecording', {'fps': 30, 'audio': true});
      ref.read(recorderStateProvider.notifier).state = RecorderState.recording;
      ref.read(recordingSecondsProvider.notifier).state = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        ref.read(recordingSecondsProvider.notifier).state += 1;
      });
    } on PlatformException catch (error) {
      setState(() => _error = '无法开始录制：${error.message}');
    } on MissingPluginException {
      setState(() => _error = '当前平台未实现录课桥接（桌面端请安装 desktop_screen_recorder）');
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stopRecording');
      ref.read(recorderStateProvider.notifier).state = RecorderState.stopped;
      if (result != null && mounted) {
        final path = result['path'] as String?;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(path != null ? '已保存：$path' : '录制已停止')),
        );
      }
    } on PlatformException catch (error) {
      setState(() => _error = '停止录制失败：${error.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recorderStateProvider);
    final seconds = ref.watch(recordingSecondsProvider);
    final book = ref.watch(selectedBookProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('录课'), actions: [
        if (book != null) Padding(padding: const EdgeInsets.only(right: 12), child: Center(child: Text('《${book.title}》'))),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 200,
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
              child: const Center(child: Text('合成画布：阅读器页面 + 摄像头小窗 + 手写标注层', style: TextStyle(color: Colors.white70))),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (state == RecorderState.recording)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _stop,
                    icon: const Icon(Icons.stop),
                    label: Text('停止（${formatDuration(seconds)}）'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.videocam),
                    label: const Text('开始录制'),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            Text('说明', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            const Text(
              '• 桌面端：desktop_screen_recorder，H.264 输出 MP4\n'
              '• iPad：ReplayKit，通过 ios/Runner/ReplayKitBridge.swift 调用\n'
              '• Android：MediaProjection，通过 MediaProjectionBridge.kt 调用\n'
              '• 录制结束后在书籍的 recordings/ 目录生成视频与同名 JSON 元数据',
            ),
          ],
        ),
      ),
    );
  }
}

/// 秒 → mm:ss。
String formatDuration(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
