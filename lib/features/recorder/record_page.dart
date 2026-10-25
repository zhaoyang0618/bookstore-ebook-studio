/// 录课（设计文档 3.5）。
///
/// 原生实现（channel `ebook_studio/recorder`）：
/// - macOS：`AVCaptureScreenInput` 录整个屏幕（见
///   `macos/Runner/ScreenRecorderBridge.swift`）
/// - iOS：**仅录本应用窗口** —— `drawHierarchy` 逐帧渲染自己的视图树 +
///   `AVAssetWriter`，不需要屏幕录制权限（见 `ios/Runner/ReplayKitBridge.swift`）
/// - Android：**仅 Android 14+**，MediaProjection + MediaRecorder；系统
///   授权框自带「单个应用 / 整个屏幕」选择（录制范围由用户挑）
///   （见 `MediaProjectionBridge.kt`）
/// - Windows：**仅录本应用窗口** —— `PrintWindow` 逐帧抓取 +
///   Media Foundation 编码 H.264（见 `windows/runner/recorder_bridge.cpp`；
///   v1 暂不含音频）
/// - Linux：暂未实现，Dart 侧直接给出明确提示
///
/// 停止后由 [RecordingRepository] 把视频挪到最终位置并写同名 JSON
/// 元数据（设计文档 1.7），列表支持回放与删除。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../library/library_page.dart';
import '../../models/mylibrary_models.dart';
import '../../storage/my_library_store.dart';
import 'recording_catalog.dart';

/// Platform Channel 名称（与各端原生实现一致）。
const String _recorderChannel = 'ebook_studio/recorder';

/// 录制状态。
enum RecorderState { idle, recording, stopped }

/// 录制状态。
final recorderStateProvider = StateProvider<RecorderState>((ref) => RecorderState.idle);

/// 已录制的秒数（UI 计时；停止后以原生返回值为准）。
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
  bool _withAudio = true;

  /// 当前目录下的录课仓库；书 / 目录变化时重建。
  RecordingRepository? _repository;
  String? _repositoryKey;

  /// 保存位置（显示给用户，免得找不到视频）。
  String? _saveDir;

  List<Recording> _recordings = const [];

  @override
  void initState() {
    super.initState();
    _reloadRecordings();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 当前书（独立文件优先，与阅读器一致）。
  ///
  /// 用 ref.read：这个方法既在 build 里用，也会在异步流程里用
  /// （Riverpod 禁止在 build 之外 watch）。
  (Book?, String?) get _context {
    final standalone = ref.read(standaloneFileProvider);
    final libraryBook = ref.read(selectedBookProvider);
    final root = ref.read(libraryRootProvider);
    if (standalone != null) {
      final book = Book(
        id: 'standalone:$standalone',
        title: p.basenameWithoutExtension(standalone),
        author: p.basename(standalone),
        format: BookFormat.txt,
        relativePath: standalone,
        sizeBytes: 0,
        addedAt: DateTime.now().toUtc().toIso8601String(),
        syncState: const BookSyncState(
          metadata: SyncState.localOnly,
          cover: SyncState.missing,
          notes: SyncState.localOnly,
          file: SyncState.localOnly,
          recordings: SyncState.localOnly,
        ),
        heldBy: const [],
      );
      return (book, null);
    }
    return (libraryBook, root);
  }

  /// 解析录课仓库目录：书目录 recordings/ 或应用文档 recordings/。
  Future<RecordingRepository> _resolveRepository() async {
    final (book, root) = _context;
    final key = '${book?.id ?? '-'}|$root';
    if (_repository != null && _repositoryKey == key) return _repository!;
    String dir;
    if (book != null && root != null) {
      dir = p.join(root, recordingsDirOf(book));
    } else {
      final docs = await getApplicationDocumentsDirectory();
      dir = p.join(docs.path, 'recordings');
    }
    _repository = RecordingRepository(dir);
    _repositoryKey = key;
    _saveDir = dir;
    return _repository!;
  }

  Future<void> _reloadRecordings() async {
    final repository = await _resolveRepository();
    if (!mounted) return;
    setState(() => _recordings = repository.list());
  }

  /// 平台是否支持录课桥接。不支持时给出明确原因（而不是让用户
  /// 点了才开始才失败）。
  String? _unsupportedReason() {
    if (Platform.isLinux) return 'Linux 端录制尚未实现（规划：PipeWire）';
    if (Platform.isAndroid) {
      // 只做 Android 14+：MIRROR_MODE_APP_ONLY 才能只录本应用窗口
      final match = RegExp(r'Android (\d+)').firstMatch(Platform.operatingSystemVersion);
      final sdk = match != null ? int.tryParse(match.group(1)!) : null;
      if (sdk != null && sdk < 14) return '录制需要 Android 14 及以上（用于只录本应用窗口）';
    }
    return null;
  }

  /// 录制范围说明（各端能力不同，见文件头注释）。
  String get _captureScopeText {
    if (Platform.isIOS || Platform.isWindows) return '仅录制本应用窗口的内容';
    if (Platform.isMacOS) return '录制整个屏幕（阅读器 + 手写标注都会被录进去）';
    if (Platform.isAndroid) return '开始时在系统弹窗里选择「单个应用」或「整个屏幕」';
    return '';
  }

  /// Windows 端 v1 只实现视频轨。
  bool get _audioSupported => !Platform.isWindows;

  Future<void> _start() async {
    final unsupported = _unsupportedReason();
    if (unsupported != null) {
      setState(() => _error = unsupported);
      return;
    }
    setState(() => _error = null);
    try {
      await _channel.invokeMethod('startRecording', {'fps': 30, 'audio': _withAudio});
      ref.read(recorderStateProvider.notifier).state = RecorderState.recording;
      ref.read(recordingSecondsProvider.notifier).state = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        ref.read(recordingSecondsProvider.notifier).state += 1;
      });
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
      ref.read(recorderStateProvider.notifier).state = RecorderState.stopped;
      if (!mounted) return;
      final sourcePath = result?['path'] as String?;
      final nativeSeconds = (result?['duration_seconds'] as num?)?.toInt();
      final seconds = (nativeSeconds != null && nativeSeconds > 0)
          ? nativeSeconds
          : ref.read(recordingSecondsProvider.notifier).state;
      if (sourcePath == null || !File(sourcePath).existsSync()) {
        setState(() => _error = '录制结束，但没有拿到视频文件（可能是权限被收回）');
        return;
      }
      await _saveRecording(sourcePath, seconds);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('录制完成（${formatDuration(seconds)}），已保存')),
      );
    } on PlatformException catch (error) {
      setState(() => _error = '停止录制失败：${error.message ?? error.code}');
    }
  }

  /// 把原生层的临时视频挪到最终位置并写元数据。
  Future<void> _saveRecording(String sourcePath, int seconds) async {
    final (book, root) = _context;
    final repository = await _resolveRepository();
    final fileName = recordingFileName(DateTime.now());
    final recording = buildRecording(
      videoFileName: fileName,
      durationSeconds: seconds,
      sizeBytes: File(sourcePath).lengthSync(),
      bookId: (book != null && root != null) ? book.id : '',
      title: (book != null && root != null) ? '${book.title} · ${_defaultTitleOf()}' : null,
      positionAtStart: book?.readingPosition?.position,
    );
    try {
      repository.importVideo(sourcePath: sourcePath, recording: recording);
    } on FileSystemException catch (error) {
      setState(() => _error =
          '保存到 ${repository.dir} 失败：${error.osError?.message ?? error.message}\n视频仍留在：$sourcePath');
      return;
    }
    await _reloadRecordings();
  }

  String _defaultTitleOf() {
    String two(int value) => value.toString().padLeft(2, '0');
    final now = DateTime.now();
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
  }

  Future<void> _deleteRecording(Recording recording) async {
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
    final repository = await _resolveRepository();
    repository.delete(recording);
    await _reloadRecordings();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recorderStateProvider);
    final seconds = ref.watch(recordingSecondsProvider);
    final (book, root) = _context;
    final inLibrary = book != null && root != null;

    return Scaffold(
      appBar: AppBar(title: const Text('录课'), actions: [
        if (book != null)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: Text('《${book.title}》${inLibrary ? '' : ' · 独立文件'}')),
          ),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RecordingStatus(
              state: state,
              seconds: seconds,
              withAudio: _withAudio,
              scopeText: _captureScopeText,
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
                const SizedBox(width: 16),
                if (state != RecorderState.recording)
                  FilterChip(
                    label: Text(_withAudio ? '含麦克风音频' : '无音频'),
                    selected: _withAudio,
                    onSelected: _audioSupported ? (value) => setState(() => _withAudio = value) : null,
                    tooltip: _audioSupported ? null : 'Windows 端暂不支持录制音频',
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Text('录制记录', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh), onPressed: _reloadRecordings),
              ],
            ),
            if (_saveDir != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '保存位置：$_saveDir',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Expanded(child: _RecordingsList(
              recordings: _recordings,
              repository: _repository,
              onPlay: _play,
              onDelete: _deleteRecording,
            )),
          ],
        ),
      ),
    );
  }

  Future<void> _play(Recording recording) async {
    final repository = await _resolveRepository();
    final path = repository.videoPathOf(recording);
    if (!mounted) return;
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
}

/// 录制状态卡。
class _RecordingStatus extends StatelessWidget {
  const _RecordingStatus({
    required this.state,
    required this.seconds,
    required this.withAudio,
    required this.scopeText,
  });

  final RecorderState state;
  final int seconds;
  final bool withAudio;
  final String scopeText;

  @override
  Widget build(BuildContext context) {
    final recording = state == RecorderState.recording;
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: recording ? const Color(0xFF2A0E0E) : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: recording ? Colors.red.shade700 : Colors.transparent),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              recording ? Icons.radio_button_checked : Icons.videocam,
              color: recording ? Colors.red : null,
              size: 36,
            ),
            const SizedBox(height: 8),
            Text(
              recording ? '正在录制屏幕${withAudio ? '与麦克风' : ''} · ${formatDuration(seconds)}' : '就绪',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              scopeText,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 录制记录列表。
class _RecordingsList extends StatelessWidget {
  const _RecordingsList({
    required this.recordings,
    required this.repository,
    required this.onPlay,
    required this.onDelete,
  });

  final List<Recording> recordings;
  final RecordingRepository? repository;
  final void Function(Recording) onPlay;
  final void Function(Recording) onDelete;

  @override
  Widget build(BuildContext context) {
    if (repository == null) {
      return const Center(child: Text('选择一本书后，录课会保存到该书目录下'));
    }
    if (recordings.isEmpty) {
      return Center(
        child: Text(
          '还没有录制\n点击「开始录制」创建第一段录课',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.separated(
      itemCount: recordings.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final recording = recordings[index];
        final duration = formatDuration(recording.durationSeconds);
        return ListTile(
          leading: const Icon(Icons.smart_display_outlined),
          title: Text(recording.title, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '$duration · ${(recording.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB · ${recording.file}',
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(tooltip: '播放', icon: const Icon(Icons.play_circle_outline), onPressed: () => onPlay(recording)),
              IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline), onPressed: () => onDelete(recording)),
            ],
          ),
        );
      },
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
                    child: Text(widget.title, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
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
                  value: total.inMilliseconds == 0
                      ? 0
                      : position.inMilliseconds / total.inMilliseconds,
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
