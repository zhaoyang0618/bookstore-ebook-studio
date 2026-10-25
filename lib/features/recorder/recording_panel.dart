/// 内容录制面板（录课子功能，设计文档 3.5）。
///
/// 录课不再是独立页面，而是**阅读器 / 笔记编辑器里的子功能**：
/// 只录内容区域（阅读内容 / 笔记页面），不录应用界面框架。
///
/// ## 机制
///
/// Dart 把内容区在窗口内的矩形（逻辑坐标）与目标分辨率传给原生层，
/// 原生各自实现「抓窗口 → 裁剪矩形 → 缩放到目标分辨率 → 编码 MP4」：
/// - iOS：`drawHierarchy` 渲染窗口 + 上下文裁剪（只需麦克风权限）
/// - Android：`PixelCopy` 抓自己窗口 + MediaCodec/MediaMuxer（无需投屏授权）
/// - Windows：`PrintWindow` + Media Foundation（无需权限，v1 无音频）
/// - macOS：`CGWindowListCreateImage` 抓自己窗口裁剪（需 TCC 屏幕录制权限）
///
/// 笔记录制开始前会自动复位缩放（整页入镜）；录制中翻页 / 翻页都会
/// 被录进去。内容区矩形在**开始时确定**，之后窗口缩放不做跟随。
///
/// @module ebook-studio/features/recorder/recording_panel
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../storage/my_library_store.dart';
import 'recording_catalog.dart';

/// Platform Channel 名称（与各端原生实现一致）。
const String _recorderChannel = 'ebook_studio/recorder';

/// 目标分辨率（长边像素；内容区按自身长宽比缩放，宽高取偶）。
enum RecordingResolution {
  p720(720, '720p'),
  p1080(1080, '1080p'),
  native(0, '跟随窗口');

  const RecordingResolution(this.longSide, this.label);

  /// 长边目标像素；0 = 不缩放（用窗口原始像素）。
  final int longSide;
  final String label;
}

/// 由内容区逻辑矩形计算裁剪矩形（物理像素）与输出尺寸（纯函数，可单测）。
///
/// 分辨率档位的语义是**短边**像素：横屏内容 1080p → 1920×1080（惯例），
/// 竖屏笔记页 1080p → 1080×1528；「跟随窗口」用内容区原始物理像素。
({Rect cropLogical, int outW, int outH}) computeCapture(
  Rect contentLogical,
  double devicePixelRatio,
  RecordingResolution resolution,
) {
  int even(double v) => max(2, (v.floor()) & ~1);

  // 裁剪矩形取物理像素（各端窗口/客户区都是物理像素语义）
  final crop = Rect.fromLTWH(
    (contentLogical.left * devicePixelRatio).floorToDouble(),
    (contentLogical.top * devicePixelRatio).floorToDouble(),
    even(contentLogical.width * devicePixelRatio).toDouble(),
    even(contentLogical.height * devicePixelRatio).toDouble(),
  );

  if (resolution.longSide == 0) {
    return (cropLogical: crop, outW: crop.width.toInt(), outH: crop.height.toInt());
  }
  final shortSide = min(crop.width, crop.height);
  if (shortSide <= 0) {
    return (cropLogical: crop, outW: crop.width.toInt(), outH: crop.height.toInt());
  }
  final scale = resolution.longSide / shortSide;
  return (
    cropLogical: crop,
    outW: even(crop.width * scale),
    outH: even(crop.height * scale),
  );
}

/// 录像的归属与落点（阅读器 = 书目录；笔记 = MyLibrary/recordings/）。
class RecordingTarget {
  const RecordingTarget({
    required this.scopeLabel,
    required this.resolveDir,
    this.bookId,
    this.ownerId,
    required this.ownerTitle,
    this.positionAtStart,
    this.audioSupported = true,
  });

  /// 界面文案：录的是「电子书」还是「笔记」。
  final String scopeLabel;

  /// 录像目录（图书馆书的书目录 / 独立或笔记的 recordings 目录）。
  final Future<String> Function() resolveDir;

  /// 图书馆内的书 id（写元数据 book_id；null = 非图书馆书）。
  final String? bookId;

  /// 录像列表的归属过滤（如 `notebook:{id}`；null = 不过滤）。
  final String? ownerId;

  /// 默认标题前缀。
  final String ownerTitle;

  /// position_at_start（设计文档 1.7）。
  final String? positionAtStart;

  /// 该平台该场景是否支持音频（Windows v1 仅视频）。
  final bool audioSupported;
}

/// 录制工具条：开始/停止 + 分辨率 + 音频开关 + 录制记录入口。
///
/// [contentKey] 指向被录的内容区（用于取窗口内矩形）；
/// [onBeforeStart] 在取矩形前执行（笔记用它复位缩放，保证整页入镜）。
class RecordingPanel extends StatefulWidget {
  const RecordingPanel({
    required this.target,
    required this.contentKey,
    this.onBeforeStart,
    super.key,
  });

  final RecordingTarget target;
  final GlobalKey contentKey;
  final Future<void> Function()? onBeforeStart;

  @override
  State<RecordingPanel> createState() => _RecordingPanelState();
}

class _RecordingPanelState extends State<RecordingPanel> {
  static const MethodChannel _channel = MethodChannel(_recorderChannel);

  bool _recording = false;
  int _seconds = 0;
  String? _error;
  bool _withAudio = true;
  RecordingResolution _resolution = RecordingResolution.p1080;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await widget.onBeforeStart?.call();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final box = widget.contentKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        setState(() => _error = '内容区尚未就绪，稍后再试');
        return;
      }
      final contentRect = box.localToGlobal(Offset.zero) & box.size;
      final dpr = View.of(context).devicePixelRatio;
      final capture = computeCapture(contentRect, dpr, _resolution);
      if (capture.outW < 16 || capture.outH < 16) {
        setState(() => _error = '内容区尺寸过小，无法录制');
        return;
      }

      await _channel.invokeMethod('startRecording', {
        'fps': 30,
        'audio': widget.target.audioSupported && _withAudio,
        'crop': {
          'x': capture.cropLogical.left,
          'y': capture.cropLogical.top,
          'w': capture.cropLogical.width,
          'h': capture.cropLogical.height,
        },
        'out': {'w': capture.outW, 'h': capture.outH},
      });
      setState(() {
        _recording = true;
        _error = null;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _seconds += 1));
    } on PlatformException catch (error) {
      setState(() => _error = '无法开始录制：${error.message ?? error.code}');
    } on MissingPluginException {
      setState(() => _error = '当前平台未实现录课桥接');
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stopRecording');
      if (!mounted) return;
      setState(() => _recording = false);
      final sourcePath = result?['path'] as String?;
      final nativeSeconds = (result?['duration_seconds'] as num?)?.toInt();
      final seconds = (nativeSeconds != null && nativeSeconds > 0) ? nativeSeconds : _seconds;
      if (sourcePath == null || !File(sourcePath).existsSync()) {
        setState(() => _error = '录制结束，但没有拿到视频文件');
        return;
      }
      await _saveRecording(sourcePath, seconds);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('录制完成（${formatDuration(seconds)}），已保存')),
      );
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = '停止录制失败：${error.message ?? error.code}');
    }
  }

  Future<void> _saveRecording(String sourcePath, int seconds) async {
    final dir = await widget.target.resolveDir();
    final repository = RecordingRepository(dir);
    final now = DateTime.now();
    final recording = buildRecording(
      videoFileName: recordingFileName(now),
      durationSeconds: seconds,
      sizeBytes: File(sourcePath).lengthSync(),
      bookId: widget.target.bookId ?? '',
      title: '${widget.target.ownerTitle} · ${_defaultTitle(now)}',
      positionAtStart: widget.target.positionAtStart,
    );
    try {
      repository.importVideo(sourcePath: sourcePath, recording: recording);
    } on FileSystemException catch (error) {
      setState(() => _error =
          '保存到 $dir 失败：${error.osError?.message ?? error.message}\n视频仍留在：$sourcePath');
      return;
    }
  }

  Future<void> _showRecordings() async {
    final dir = await widget.target.resolveDir();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => RecordingsSheet(dir: dir, ownerId: widget.target.ownerId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (_recording)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _stop,
                    icon: const Icon(Icons.stop),
                    label: Text('停止（${formatDuration(_seconds)}）'),
                  )
                else ...[
                  FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.videocam),
                    label: const Text('开始录制'),
                  ),
                  const SizedBox(width: 10),
                  TextButton.icon(
                    onPressed: _showRecordings,
                    icon: const Icon(Icons.video_library_outlined, size: 18),
                    label: const Text('录制记录'),
                  ),
                ],
                const Spacer(),
                if (widget.target.audioSupported && !_recording)
                  FilterChip(
                    label: Text(_withAudio ? '含麦克风' : '无音频'),
                    selected: _withAudio,
                    onSelected: (value) => setState(() => _withAudio = value),
                  ),
              ],
            ),
            if (!_recording)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('分辨率', style: theme.textTheme.labelSmall),
                    for (final item in RecordingResolution.values)
                      ChoiceChip(
                        label: Text(item.label, style: theme.textTheme.labelSmall),
                        selected: _resolution == item,
                        onSelected: (_) => setState(() => _resolution = item),
                      ),
                  ],
                ),
              ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _defaultTitle(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

/// 录制记录（底部弹层）：列表 + 回放 + 删除。
class RecordingsSheet extends StatefulWidget {
  const RecordingsSheet({required this.dir, this.ownerId, super.key});

  final String dir;

  /// 只显示归属该 id 的录像（book_id 前缀匹配）；null = 全部。
  final String? ownerId;

  @override
  State<RecordingsSheet> createState() => _RecordingsSheetState();
}

class _RecordingsSheetState extends State<RecordingsSheet> {
  late final RecordingRepository _repository = RecordingRepository(widget.dir);
  List<Recording> _recordings = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final all = _repository.list();
    final ownerId = widget.ownerId;
    setState(() {
      _recordings = ownerId == null ? all : all.where((r) => r.bookId == ownerId).toList();
    });
  }

  Future<void> _play(Recording recording) async {
    final path = _repository.videoPathOf(recording);
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('视频文件不存在：$path\n（元数据还在，可能被移动或删除）')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _VideoPlayerDialog(path: path, title: recording.title),
    );
  }

  Future<void> _delete(Recording recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这段录课？'),
        content: Text('「${recording.title}」的视频与元数据都会被删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    _repository.delete(recording);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('录制记录', style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh), onPressed: _reload),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '保存位置：${widget.dir}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Divider(),
            Flexible(
              child: _recordings.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text('还没有录制\n点击「开始录制」创建第一段录课',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _recordings.length,
                      itemBuilder: (context, index) {
                        final recording = _recordings[index];
                        return ListTile(
                          leading: const Icon(Icons.smart_display_outlined),
                          title: Text(recording.title, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${formatDuration(recording.durationSeconds)} · '
                            '${(recording.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB · '
                            '${p.basename(recording.file)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                  tooltip: '播放',
                                  icon: const Icon(Icons.play_circle_outline),
                                  onPressed: () => _play(recording)),
                              IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _delete(recording)),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频回放对话框。
class _VideoPlayerDialog extends StatefulWidget {
  const _VideoPlayerDialog({required this.path, required this.title});

  final String path;
  final String title;

  @override
  State<_VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<_VideoPlayerDialog> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.file(File(widget.path));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } on MissingPluginException {
      if (mounted) setState(() => _error = '当前平台没有视频解码实现（Windows / Linux 暂不支持回放）');
    } catch (error) {
      if (mounted) setState(() => _error = '无法播放：$error');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    )
                  : controller == null
                      ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                      : AspectRatio(
                          aspectRatio: controller.value.aspectRatio == 0 ? 16 / 9 : controller.value.aspectRatio,
                          child: Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              VideoPlayer(controller),
                              _VideoControls(controller: controller),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放控制条：播放 / 暂停 + 进度。
class _VideoControls extends StatelessWidget {
  const _VideoControls({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final position = controller.value.position;
        final total = controller.value.duration;
        return Container(
          color: Colors.black45,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              IconButton(
                color: Colors.white,
                icon: Icon(controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () {
                  controller.value.isPlaying ? controller.pause() : controller.play();
                },
              ),
              Expanded(
                child: Slider(
                  value: total.inMilliseconds == 0 ? 0 : position.inMilliseconds / total.inMilliseconds,
                  onChanged: (value) {
                    controller.seekTo(total * value);
                  },
                ),
              ),
              Text(
                '${formatDuration(position.inSeconds)} / ${formatDuration(total.inSeconds)}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 秒 → mm:ss。
String formatDuration(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 独立模式（未配置图书馆）的录像目录：应用文档目录 recordings/。
Future<String> standaloneRecordingsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return p.join(docs.path, 'recordings');
}
