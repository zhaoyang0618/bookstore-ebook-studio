/// 笔记本编辑器（GoodNotes / Notability 风格手写页）。
///
/// ## 交互设计
///
/// - 单指 / 鼠标：书写（笔 / 记号笔 / 荧光笔）或擦除（笔画擦）
/// - 双指：平移 + 缩放（第一笔会被取消，符合「两指=手势」直觉）
/// - 滚轮：平移；Ctrl / ⌘ + 滚轮以光标为中心缩放（桌面端）
/// - 缩放下限是「铺满窗口」：纸永远不会小于视口，任何位置都能落笔
/// - 工具栏：缩放按钮 / 翻页 / 加删页 / 纸张模板
///
/// ## 实现
///
/// 不用 `InteractiveViewer`：它的单指平移手势会和手写竞争
/// （阅读器里靠 `AbsorbPointer` 二选一，笔记必须「单指写、双指移」
/// 同时成立）。因此自己维护 `TransformationController`，框架层
/// `Transform` 只做呈现 —— 命中测试会把指针坐标逆变换回**笔记页
/// 坐标**，笔迹直接按页坐标存储，与缩放无关。
///
/// 笔迹复用阅读器的矢量结构（`InkStroke`，见 ink_canvas.dart），
/// 落盘走 [NotebookSession]（撤销 / 重做 / 自动保存）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../library/library_page.dart';
import '../../util/app_log.dart';
import '../annotation/ink_canvas.dart';
import '../annotation/pdf_ink.dart' show paintLocalStrokes;
import '../recorder/recording_panel.dart';
import 'notebook_store.dart';

/// 工具。
///
/// [pan] 是「移动」模式：拖动 = 平移画布，不能画线
/// （桌面鼠标没有双指手势，靠它移动页面）。
enum NotebookTool { pen, marker, highlighter, eraser, pan }

/// 笔画粗细档位（乘在工具默认线宽上）。
const List<double> kWidthScales = [0.6, 1.0, 1.8];

/// 擦除半径（笔记页坐标单位）。
const double _eraserRadius = 14;

String _fmt(Offset o) =>
    '(${o.dx.toStringAsFixed(1)}, ${o.dy.toStringAsFixed(1)})';

String _kindName(PointerDeviceKind kind) => switch (kind) {
      PointerDeviceKind.mouse => 'mouse',
      PointerDeviceKind.touch => 'touch',
      PointerDeviceKind.stylus => 'stylus',
      PointerDeviceKind.invertedStylus => 'invStylus',
      PointerDeviceKind.trackpad => 'trackpad',
      _ => kind.toString(),
    };

class NotebookEditorPage extends ConsumerStatefulWidget {
  const NotebookEditorPage({
    required this.notebook,
    required this.store,
    required this.onSaved,
    super.key,
  });

  final Notebook notebook;
  final NotebookStore store;

  /// 每次落盘后回调（图书馆页刷新元数据用）。
  final void Function(Notebook notebook) onSaved;

  @override
  ConsumerState<NotebookEditorPage> createState() => _NotebookEditorPageState();
}

class _NotebookEditorPageState extends ConsumerState<NotebookEditorPage> {
  late NotebookSession _session;
  final TransformationController _transform = TransformationController();

  /// 被录的内容（当前笔记页画布）。
  final GlobalKey _pageKey = GlobalKey();

  bool _recordingMode = false;

  // ---- 双指 / 触控板手势（在**窗口层**处理：光标落在工具栏、标题栏
  // 附近时事件也要能平移 —— v0.9.8 日志显示上滑事件因光标位置丢失） ----
  double _panZoomScale = 1;

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    AppLog.log('panzoom', 'ROOT START id=${event.pointer} pos=${_fmt(event.position)} device=${event.kind}');
    _panZoomScale = 1;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    AppLog.log('panzoom',
        'ROOT UPDATE id=${event.pointer} panDelta=${_fmt(event.panDelta)} scale=${event.scale.toStringAsFixed(3)} pos=${_fmt(event.position)}');
    if (event.panDelta != Offset.zero) {
      _panBy(event.panDelta);
    }
    // event.scale 是手势开始以来的累计缩放，换算成这一帧的比率
    if (event.scale > 0 && _panZoomScale > 0 && event.scale != _panZoomScale) {
      _zoomAboutGlobal(event.position, event.scale / _panZoomScale);
      _panZoomScale = event.scale;
    }
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    AppLog.log('panzoom', 'ROOT END id=${event.pointer}');
  }

  void _onRootPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    AppLog.log('scroll', 'ROOT delta=${_fmt(event.scrollDelta)} ctrl=$ctrl pos=${_fmt(event.position)}');
    if (ctrl) {
      if (event.scrollDelta.dy != 0) {
        final ratio = event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1;
        _zoomAboutGlobal(event.position, ratio);
      }
      return;
    }
    if (event.scrollDelta != Offset.zero) {
      // 经典滚轮语义：向下滚（dy>0）= 看更低的内容 = 纸向上移
      _panBy(-event.scrollDelta);
    }
  }

  /// 视口（Transform 的父级坐标空间），滚轮缩放锚点换算用。
  final GlobalKey _viewportKey = GlobalKey();

  NotebookTool _tool = NotebookTool.pen;
  Color _color = const Color(0xFF212121);
  double _widthScale = 1.0;

  /// 视口尺寸（由 LayoutBuilder 算出）。
  Size _viewportSize = Size.zero;
  Size _lastViewportSize = Size.zero;

  /// 缩放下限：纸**恰好盖住视口**的缩放比（宽/高两个方向取大的）。
  ///
  /// 不允许缩得比这更小 —— 纸一旦小于窗口，四周露出背景，
  /// 背景上落笔没反应，看起来就是「某处不能画」。
  double get _coverScale {
    if (_viewportSize.isEmpty || _session.notebook.pageWidth <= 0) return 1;
    return max(
      _viewportSize.width / _session.notebook.pageWidth,
      _viewportSize.height / _session.notebook.pageHeight,
    );
  }

  /// 首帧后设置初始缩放（build 期间改 controller 会触发
  /// 「build 期间 markNeedsBuild」异常，必须推迟到帧后）。
  bool _needsInitialFit = true;

  Timer? _autosave;
  bool _saved = true;

  /// 仅供测试：当前变换矩阵（初始铺满是否生效的校验点）。
  @visibleForTesting
  Matrix4 get debugTransform => _transform.value;

  @override
  void initState() {
    super.initState();
    _session = NotebookSession(widget.notebook);
    _session.addListener(_onSessionChanged);
    AppLog.log('editor', 'initState notebook=${_session.notebook.id} pages=${_session.pageCount}');
  }

  @override
  void dispose() {
    AppLog.log('editor', 'dispose notebook=${_session.notebook.id}');
    _autosave?.cancel();
    _saveNow();
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    setState(() {});
    _scheduleSave();
  }

  /// 手写内容「画完就不能丢」：改动后 800ms 防抖落盘。
  void _scheduleSave() {
    setState(() => _saved = false);
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 800), _saveNow);
  }

  void _saveNow() {
    if (!_session.dirty) return;
    final notebook = _session.snapshot();
    widget.store.save(notebook);
    _session.dirty = false;
    _saved = true;
    widget.onSaved(notebook);
    if (mounted) setState(() {});
  }

  /// 诊断日志查看器：复现手势问题后把日志发给开发者。
  Future<void> _showDiagnostics() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _AppLogDialog(),
    );
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _session.notebook.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名笔记本'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定')),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty || title.trim() == _session.notebook.title) return;
    _session.notebook = _session.notebook.copyWith(title: title.trim());
    _scheduleSave();
    setState(() {});
  }

  Future<void> _deletePage() async {
    if (_session.pageCount <= 1) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除第 ${_session.currentPage + 1} 页？'),
        content: const Text('该页的笔迹会一并删除，此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    _session.deletePage(_session.currentPage);
  }

  /// 「铺满」矩阵（初始 / 复位状态）：用 [_coverScale]，
  /// 没铺到的那根轴上让纸居中。
  Matrix4 _coverMatrix() {
    final scale = _coverScale;
    // z 轴同缩放：getMaxScaleOnAxis 会计入 z 轴，sz=1 会让所有读缩放的
    // 逻辑（边界钳制 / 缩放下限）误以为 scale=1 —— v0.9.6 的实测 bug
    final m = Matrix4.identity()..scaleByDouble(scale, scale, scale, 1);
    final dx = max(
        0.0, (_viewportSize.width - _session.notebook.pageWidth * scale) / 2);
    final dy = max(
        0.0, (_viewportSize.height - _session.notebook.pageHeight * scale) / 2);
    if (dx > 0 || dy > 0) {
      m.translateByDouble(dx, dy, 0, 1);
    }
    return m;
  }

  /// 视口内平移：纸移动 [contentDelta]（**跟随手指 / 光标**），随后钳制边界。
  ///
  /// 各调用方传的量：
  /// - 触控板 pan-zoom：+panDelta（macOS 的 delta 已含用户的自然滚动设置，
  ///   跟随手指 = GoodNotes 行为。v0.9.7 之前这里取反了方向，用户的滑动
  ///   全被钳在页面顶部，看起来「滑动没有效果」）
  /// - 移动工具拖动：+光标位移（纸跟着光标走）
  /// - 滚轮：-scrollDelta（经典滚轮语义：向下滚 = 看更低的内容）
  void _panBy(Offset contentDelta) {
    final ops = Matrix4.identity()
      ..translateByDouble(contentDelta.dx, contentDelta.dy, 0, 1);
    ops.multiply(_transform.value);
    _transform.value = ops;
    _clampPan();
    final t = _transform.value.getTranslation();
    AppLog.log('pan', 'by=${_fmt(contentDelta)} -> translation=(${t.x.toStringAsFixed(1)}, ${t.y.toStringAsFixed(1)}) scale=${_transform.value.getMaxScaleOnAxis().toStringAsFixed(3)}');
  }

  /// 平移边界钳制：放大到能覆盖视口时，纸**不允许被拖出视野**
  /// （任何位置都能落笔）；缩得比视口还小时，保持纸完整可见。
  ///
  /// 没有这个钳制，页面可以被拖到角落 —— 露出的背景上落笔没有反应，
  /// 看起来就像「底部不能画线」。
  void _clampPan() {
    if (_viewportSize.isEmpty) return;
    final m = _transform.value;
    final scale = m.getMaxScaleOnAxis();
    if (scale <= 0) return;
    // 缩放低于「铺满」下限 → 恢复到铺满（兜底：所有缩放入口都有自己的下限）
    if (scale < _coverScale - 0.0001) {
      _transform.value = _coverMatrix();
      return;
    }
    final origin = MatrixUtils.transformPoint(m, Offset.zero);
    final contentW = _session.notebook.pageWidth * scale;
    final contentH = _session.notebook.pageHeight * scale;
    final vw = _viewportSize.width;
    final vh = _viewportSize.height;

    double dx = 0;
    if (contentW >= vw) {
      // 纸比视口宽：左边缘不能进来，右边缘不能露出去
      if (origin.dx > 0) {
        dx = -origin.dx;
      } else if (origin.dx + contentW < vw) {
        dx = vw - contentW - origin.dx;
      }
    } else {
      // 纸比视口窄：整体保持在视口内
      if (origin.dx < 0) {
        dx = -origin.dx;
      } else if (origin.dx + contentW > vw) {
        dx = vw - contentW - origin.dx;
      }
    }
    double dy = 0;
    if (contentH >= vh) {
      if (origin.dy > 0) {
        dy = -origin.dy;
      } else if (origin.dy + contentH < vh) {
        dy = vh - contentH - origin.dy;
      }
    } else {
      if (origin.dy < 0) {
        dy = -origin.dy;
      } else if (origin.dy + contentH > vh) {
        dy = vh - contentH - origin.dy;
      }
    }
    if (dx == 0 && dy == 0) return;
    AppLog.log('clamp', 'adjusted dx=${dx.toStringAsFixed(1)} dy=${dy.toStringAsFixed(1)} '
        '(content=${contentW.toStringAsFixed(0)}x${contentH.toStringAsFixed(0)} viewport=${vw.toStringAsFixed(0)}x${vh.toStringAsFixed(0)} origin=(${origin.dx.toStringAsFixed(1)}, ${origin.dy.toStringAsFixed(1)}))');
    final ops = Matrix4.identity()..translateByDouble(dx, dy, 0, 1);
    ops.multiply(m);
    _transform.value = ops;
  }

  void _setZoom(double ratio) {
    var center = _viewportSize.center(Offset.zero);
    if (center == Offset.zero) {
      final size = MediaQuery.sizeOf(context);
      center = Offset(size.width / 2, size.height / 2);
    }
    _zoomAbout(center, ratio);
  }

  /// 以**全局坐标**的 [globalCenter] 为锚点缩放（滚轮 / 触控板事件给的是
  /// 全局坐标，需换算到视口空间）。
  void _zoomAboutGlobal(Offset globalCenter, double ratio) {
    final box = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    _zoomAbout(box.globalToLocal(globalCenter), ratio);
  }

  void _zoomAbout(Offset center, double ratio) {
    final current = _transform.value.getMaxScaleOnAxis();
    final floor = _viewportSize.isEmpty ? 0.1 : _coverScale;
    final target = (current * ratio).clamp(floor, 10.0);
    final effective = target / current;
    AppLog.log('zoom', 'about=${_fmt(center)} ratio=${ratio.toStringAsFixed(3)} current=${current.toStringAsFixed(3)} -> target=${target.toStringAsFixed(3)} floor=${floor.toStringAsFixed(3)}');
    if (effective == 1) return;
    final ops = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(effective, effective, effective, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    ops.multiply(_transform.value);
    _transform.value = ops;
    _clampPan();
  }

  void _resetZoom() {
    _transform.value = _coverMatrix();
  }

  /// 笔记录像落点：图书馆内 → `MyLibrary/recordings/`（随图书馆同步）；
  /// 独立笔记本 → 应用文档 recordings/。归属 id：`notebook:{id}`。
  RecordingTarget _notebookRecordingTarget() {
    final root = ref.watch(libraryRootProvider);
    return RecordingTarget(
      scopeLabel: '笔记',
      resolveDir: () async {
        if (root != null && root.isNotEmpty) return p.join(root, 'recordings');
        return standaloneRecordingsDir();
      },
      ownerId: 'notebook:${_session.notebook.id}',
      ownerTitle: _session.notebook.title,
      audioSupported: !Platform.isWindows,
    );
  }

  @override
  Widget build(BuildContext context) {
    final notebook = _session.notebook;
    return Listener(
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomUpdate: _onPanZoomUpdate,
      onPointerPanZoomEnd: _onPanZoomEnd,
      onPointerSignal: _onRootPointerSignal,
      onPointerDown: (event) => AppLog.log('root-ptr',
          'DOWN kind=${_kindName(event.kind)} buttons=${event.buttons} global=${_fmt(event.position)} pressure=${event.pressure.toStringAsFixed(2)}'),
      onPointerUp: (event) => AppLog.log('root-ptr',
          'UP kind=${_kindName(event.kind)} global=${_fmt(event.position)}'),
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.pop(context)),
        title: GestureDetector(
          onTap: _rename,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(notebook.title, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 6),
              Icon(_saved ? Icons.cloud_done_outlined : Icons.edit_note, size: 16,
                  color: Theme.of(context).hintColor),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: '撤销',
            icon: const Icon(Icons.undo),
            onPressed: _session.canUndo ? _session.undo : null,
          ),
          IconButton(
            tooltip: '重做',
            icon: const Icon(Icons.redo),
            onPressed: _session.canRedo ? _session.redo : null,
          ),
          IconButton(
            tooltip: '添加一页',
            icon: const Icon(Icons.post_add),
            onPressed: () => _session.insertPageAfterCurrent(
              _session.notebook.pages[_session.currentPage].template,
            ),
          ),
          // 录课子功能（设计文档 3.5）：开始时自动复位缩放，整页入镜
          IconButton(
            tooltip: _recordingMode ? '退出录制' : '录制讲解（仅录笔记页）',
            icon: Icon(_recordingMode ? Icons.videocam_off : Icons.videocam_outlined),
            onPressed: () => setState(() => _recordingMode = !_recordingMode),
          ),
          IconButton(
            tooltip: '删除本页',
            icon: const Icon(Icons.delete_outline),
            onPressed: _session.pageCount > 1 ? _deletePage : null,
          ),
          IconButton(
            tooltip: '诊断日志',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _showDiagnostics,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
          // 初始缩放：**宽度铺满**（GoodNotes 行为）—— 页面横向占满窗口，
          // 纵向超出部分用双指 / 滚轮平移；不再缩成一角让人找不到纸在哪
          if (_needsInitialFit) {
            _needsInitialFit = false;
            AppLog.log('fit', 'builder: schedule initial fit, viewport=$_viewportSize cover=${_coverScale.toStringAsFixed(3)}');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              AppLog.log('fit', 'postFrame: entered, viewport=$_viewportSize mounted=$mounted');
              if (mounted) {
                _transform.value = _coverMatrix();
                AppLog.log('fit', 'postFrame: applied scale=${_transform.value.getMaxScaleOnAxis().toStringAsFixed(3)}');
              }
            });
          } else if (_lastViewportSize != _viewportSize) {
            // 窗口缩放后页面可能跑到视野外，钳一次
            _lastViewportSize = _viewportSize;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _clampPan();
            });
          }
          return ClipRect(
            key: _viewportKey,
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _transform,
                    builder: (context, _) {
                      return Transform(
                        transform: _transform.value,
                        // 页面按原始尺寸放在视口左上（OverflowBox 放开约束），
                        // 所有矩阵运算都在视口坐标系里进行
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          maxWidth: double.infinity,
                          maxHeight: double.infinity,
                          child: SizedBox(
                            key: _pageKey,
                            width: notebook.pageWidth,
                            height: notebook.pageHeight,
                            child: _NotebookPageView(
                              session: _session,
                              pageIndex: _session.currentPage,
                              tool: _tool,
                              color: _color,
                              widthScale: _widthScale,
                              onZoom: _zoomAboutGlobal,
                              onPan: _panBy,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 页码指示（纯指示器：IgnorePointer，否则会挡住中下部的落笔）
                Positioned(
                  bottom: 96,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: _PageBadge(
                        current: _session.currentPage + 1,
                        total: _session.pageCount,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: _recordingMode
          ? RecordingPanel(
              target: _notebookRecordingTarget(),
              contentKey: _pageKey,
              onBeforeStart: () async => _resetZoom(),
            )
          : SafeArea(
        child: _EditorToolbar(
          tool: _tool,
          color: _color,
          widthScale: _widthScale,
          template: _session.notebook.pages[_session.currentPage].template,
          canPrev: _session.currentPage > 0,
          canNext: _session.currentPage < _session.pageCount - 1,
          onToolChanged: (tool) => setState(() => _tool = tool),
          onColorChanged: (color) => setState(() => _color = color),
          onWidthChanged: (scale) => setState(() => _widthScale = scale),
          onTemplateChanged: (template) => _session.setPageTemplate(_session.currentPage, template),
          onZoomIn: () => _setZoom(1.2),
          onZoomOut: () => _setZoom(1 / 1.2),
          onZoomReset: _resetZoom,
          onPrevPage: () {
            _saveNow();
            setState(() => _session.currentPage -= 1);
          },
          onNextPage: () {
            _saveNow();
            setState(() => _session.currentPage += 1);
          },
        ),
      ),
      ),
    );
  }
}

/// 单页视图：纸张 + 已落定笔迹 + 捕获层。
class _NotebookPageView extends StatefulWidget {
  const _NotebookPageView({
    required this.session,
    required this.pageIndex,
    required this.tool,
    required this.color,
    required this.widthScale,
    required this.onZoom,
    required this.onPan,
  });

  final NotebookSession session;
  final int pageIndex;
  final NotebookTool tool;
  final Color color;
  final double widthScale;
  final void Function(Offset center, double ratio) onZoom;

  /// 滚轮 / 触控板滚动 → 视口内平移。
  final void Function(Offset delta) onPan;

  @override
  State<_NotebookPageView> createState() => _NotebookPageViewState();
}

class _NotebookPageViewState extends State<_NotebookPageView> {
  /// 进行中的一笔（笔记页坐标）。
  InkStroke? _current;
  DateTime? _strokeStart;

  /// 活动指针（viewport 坐标）—— 2 个及以上时进入平移/缩放。
  final Map<int, Offset> _pointers = {};
  Offset? _gestureMid;
  double? _gestureSpan;

  /// 是否处于一段连续的擦除拖动中（合并撤销记录）。
  bool _erasing = false;

  /// 移动模式：正在拖画布的指针。
  int? _panPointer;
  Offset? _lastPanPosition;

  bool get _isEraser => widget.tool == NotebookTool.eraser;

  bool get _isPanTool => widget.tool == NotebookTool.pan;

  /// 工具的页面单位线宽（存储值，与缩放无关）。
  double get _strokeWidth {
    final base = switch (widget.tool) {
      NotebookTool.pen => 2.0,
      NotebookTool.marker => 5.0,
      NotebookTool.highlighter => 16.0,
      NotebookTool.eraser => 2.0,
      NotebookTool.pan => 0.0, // 不画线，不会走到
    };
    return base * widget.widthScale;
  }

  Color get _strokeColor {
    final opacity = widget.tool == NotebookTool.highlighter ? 0.35 : 1.0;
    return widget.color.withValues(alpha: opacity);
  }

  void _onPointerDown(PointerDownEvent event) {
    AppLog.log('ptr',
        'DOWN kind=${_kindName(event.kind)} id=${event.pointer} global=${_fmt(event.position)} local=${_fmt(event.localPosition)} pressure=${event.pressure.toStringAsFixed(2)} buttons=${event.buttons}');
    // 触控板「直接触摸」指针不参与任何交互（画线 / 双指逻辑都不进）：
    // macOS 双指滑动时而被路由成裸指针，参与画线就会误画。
    // 触控板只通过 PointerPanZoom / PointerScroll 事件平移缩放。
    if (event.kind == PointerDeviceKind.trackpad) {
      AppLog.log('ptr', 'DOWN -> ignored (trackpad)');
      return;
    }
    _pointers[event.pointer] = event.position;
    // 第二根手指落下：取消正在画的笔（两指 = 平移/缩放手势）
    if (_pointers.length == 2 && _current != null) {
      _current = null;
      _strokeStart = null;
    }
    if (_pointers.length == 2) {
      final points = _pointers.values.toList();
      _gestureMid = Offset(
        (points[0].dx + points[1].dx) / 2,
        (points[0].dy + points[1].dy) / 2,
      );
      _gestureSpan = (points[0] - points[1]).distance;
      return;
    }
    if (_pointers.length > 2 || _current != null) return;

    // **没有按下任何按键**的 mouse down（macOS 会把双指滑动合成这种
    // 「拖动」，光标甚至移出窗口）—— 不是真实点击，一律忽略。
    // 真实点击 buttons ≥ 1；iPad 触摸 buttons = 1（引擎设置）。
    if (event.kind == PointerDeviceKind.mouse && event.buttons == 0) {
      AppLog.log('ptr', 'DOWN -> ignored (mouse buttons=0, synthesized drag)');
      return;
    }

    // 移动模式：拖动 = 平移画布，不能画线
    if (_isPanTool) {
      _panPointer = event.pointer;
      _lastPanPosition = event.position;
      AppLog.log('ptr', 'DOWN -> pan-drag start id=${event.pointer} at=${_fmt(event.position)}');
      return;
    }

    if (_isEraser) {
      _erasing = true;
      AppLog.log('ptr', 'DOWN -> erase-drag start id=${event.pointer}');
      widget.session.eraseAt(widget.pageIndex, event.localPosition, _eraserRadius);
      return;
    }
    _strokeStart = DateTime.now();
    _current = InkStroke(
      color: _strokeColor,
      width: _strokeWidth,
      cap: widget.tool == NotebookTool.highlighter ? StrokeCap.square : StrokeCap.round,
      points: [
        InkPoint(x: event.localPosition.dx, y: event.localPosition.dy, t: 0),
      ],
    );
    AppLog.log('ptr', 'DOWN -> stroke-start id=${event.pointer} at=${_fmt(event.localPosition)}');
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.trackpad) {
      AppLog.log('ptr', 'MOVE kind=trackpad id=${event.pointer} global=${_fmt(event.position)} local=${_fmt(event.localPosition)} -> ignored');
      return;
    }
    if (_pointers.containsKey(event.pointer)) {
      _pointers[event.pointer] = event.position;
    }
    if (_pointers.length >= 2) {
      AppLog.log('ptr', 'MOVE id=${event.pointer} pointers=${_pointers.length} -> two-finger gesture');
      _applyTwoFingerGesture();
      return;
    }
    // 移动模式：单指 / 鼠标拖动平移画布
    if (_panPointer == event.pointer && _lastPanPosition != null) {
      final delta = event.position - _lastPanPosition!;
      AppLog.log('ptr', 'MOVE id=${event.pointer} -> pan-drag delta=${_fmt(delta)}');
      widget.onPan(delta);
      _lastPanPosition = event.position;
      return;
    }
    final current = _current;
    if (current == null) {
      // 无按键 mouse 的 move（合成拖动）：只平移（移动模式已处理），不画
      if (_isPanTool && _panPointer == null && event.kind == PointerDeviceKind.mouse && event.buttons == 0) {
        widget.onPan(event.delta);
      }
      if (_isEraser && _pointers.isNotEmpty) {
        // 橡皮拖动持续擦；整段拖动合并为一次撤销
        widget.session.eraseAt(widget.pageIndex, event.localPosition, _eraserRadius, mergeWithLast: _erasing);
      } else {
        AppLog.log('ptr', 'MOVE id=${event.pointer} no-current (dropped) local=${_fmt(event.localPosition)}');
      }
      return;
    }
    final elapsed = DateTime.now().difference(_strokeStart ?? DateTime.now()).inMilliseconds;
    current.points.add(InkPoint(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      pressure: event.pressure > 0 ? event.pressure.clamp(0.0, 1.0) : 1,
      t: elapsed,
    ));
    if (current.points.length % 20 == 0) {
      AppLog.log('ptr', 'MOVE stroke id=${event.pointer} pts=${current.points.length} last=${_fmt(event.localPosition)}');
    }
    setState(() {});
  }

  void _onPointerUp(PointerEvent event) {
    AppLog.log('ptr', 'UP kind=${_kindName(event.kind)} id=${event.pointer} global=${_fmt(event.position)} local=${_fmt(event.localPosition)}');
    // trackpad 指针从未参与：提前忽略，避免误提交正在画的笔迹
    if (event.kind == PointerDeviceKind.trackpad) {
      AppLog.log('ptr', 'UP -> ignored (trackpad)');
      return;
    }
    _pointers.remove(event.pointer);
    if (_panPointer == event.pointer) {
      _panPointer = null;
      _lastPanPosition = null;
    }
    _erasing = false;
    if (_pointers.isEmpty) {
      _gestureMid = null;
      _gestureSpan = null;
    }
    final stroke = _current;
    _current = null;
    _strokeStart = null;
    if (stroke != null && stroke.points.isNotEmpty) {
      AppLog.log('ptr', 'UP -> stroke commit id=${event.pointer} pts=${stroke.points.length} '
          'first=${_fmt(Offset(stroke.points.first.x, stroke.points.first.y))} '
          'last=${_fmt(Offset(stroke.points.last.x, stroke.points.last.y))}');
      widget.session.addStroke(widget.pageIndex, stroke);
    } else if (stroke != null) {
      AppLog.log('ptr', 'UP -> stroke empty (dropped) id=${event.pointer}');
    }
    setState(() {});
  }

  /// 双指平移 + 缩放：保持两指中点跟随、两指间距决定缩放比。
  void _applyTwoFingerGesture() {
    final points = _pointers.values.toList();
    if (points.length < 2 || _gestureMid == null || _gestureSpan == null) return;
    final mid = Offset((points[0].dx + points[1].dx) / 2, (points[0].dy + points[1].dy) / 2);
    final span = (points[0] - points[1]).distance;
    if (_gestureSpan! <= 0 || span <= 0) return;
    final ratio = (span / _gestureSpan!).clamp(0.5, 2.0);
    widget.onZoom(_gestureMid!, ratio);
    // 中点移动的平移量（走 onPan，带边界钳制）
    widget.onPan(mid - _gestureMid!);
    _gestureMid = mid;
    _gestureSpan = span;
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.session.notebook.pages[widget.pageIndex];
    final strokes = widget.session.strokesOf(widget.pageIndex);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: CustomPaint(
        painter: _NotebookPaperPainter(template: page.template, pageSize: _pageSize),
        isComplex: true,
        willChange: false,
        child: CustomPaint(
          painter: _PageStrokesPainter(
            strokes: strokes,
            current: _current,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Size get _pageSize => Size(
        widget.session.notebook.pageWidth,
        widget.session.notebook.pageHeight,
      );
}

/// 已落定笔迹 + 进行中笔迹的绘制器（全部是笔记页坐标）。
class _PageStrokesPainter extends CustomPainter {
  const _PageStrokesPainter({required this.strokes, this.current});

  final List<InkStroke> strokes;
  final InkStroke? current;

  @override
  void paint(Canvas canvas, Size size) {
    // 页面坐标 == 局部坐标；笔迹裁剪在纸面内（画出纸外的部分不可见）
    canvas.clipRect(Offset.zero & size);
    // 页面坐标 == 局部坐标，displayedSize == pageSize
    paintLocalStrokes(canvas, strokes);
    final draft = current;
    if (draft != null) {
      paintLocalStrokes(canvas, [draft]);
    }
  }

  @override
  bool shouldRepaint(_PageStrokesPainter oldDelegate) => true;
}

/// 纸张模板绘制器：横线 / 方格 / 点阵 + 左侧红色页边线（GoodNotes 风）。
class _NotebookPaperPainter extends CustomPainter {
  const _NotebookPaperPainter({required this.template, required this.pageSize});

  final NotebookTemplate template;
  final Size pageSize;

  static const Color _paper = Color(0xFFFDFDFB);
  static const Color _line = Color(0xFFC9D4E3);
  static const Color _dot = Color(0xFFB9C4D4);
  static const Color _margin = Color(0xFFE28A8A);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);

    final line = Paint()
      ..color = _line
      ..strokeWidth = 1;
    final dot = Paint()..color = _dot;

    // 纸张边界：细灰框，让页面在背景上一眼可辨
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0x33000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    switch (template) {
      case NotebookTemplate.blank:
        break;
      case NotebookTemplate.ruled:
        const spacing = 48.0;
        for (var y = spacing; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        // 红色页边线（GoodNotes 风格）
        canvas.drawLine(const Offset(96, 0), Offset(96, size.height), Paint()..color = _margin..strokeWidth = 1.5);
        break;
      case NotebookTemplate.grid:
        const spacing = 32.0;
        for (var x = spacing; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
        for (var y = spacing; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        break;
      case NotebookTemplate.dots:
        const spacing = 32.0;
        for (var x = spacing; x < size.width; x += spacing) {
          for (var y = spacing; y < size.height; y += spacing) {
            canvas.drawCircle(Offset(x, y), 1.6, dot);
          }
        }
        break;
    }
  }

  @override
  bool shouldRepaint(_NotebookPaperPainter oldDelegate) =>
      oldDelegate.template != template || oldDelegate.pageSize != pageSize;
}

/// 页码徽标。
class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$current / $total',
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

/// 底部工具栏：工具 / 颜色 / 粗细 / 纸张 / 缩放 / 翻页。
class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.tool,
    required this.color,
    required this.widthScale,
    required this.template,
    required this.canPrev,
    required this.canNext,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onWidthChanged,
    required this.onTemplateChanged,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomReset,
    required this.onPrevPage,
    required this.onNextPage,
  });

  final NotebookTool tool;
  final Color color;
  final double widthScale;
  final NotebookTemplate template;
  final bool canPrev;
  final bool canNext;
  final ValueChanged<NotebookTool> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onWidthChanged;
  final ValueChanged<NotebookTemplate> onTemplateChanged;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;
  final VoidCallback onPrevPage;
  final VoidCallback onNextPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<NotebookTool>(
            segments: const [
              ButtonSegment(value: NotebookTool.pen, icon: Icon(Icons.edit, size: 18), tooltip: '钢笔'),
              ButtonSegment(value: NotebookTool.marker, icon: Icon(Icons.brush, size: 18), tooltip: '记号笔'),
              ButtonSegment(value: NotebookTool.highlighter, icon: Icon(Icons.format_color_fill, size: 18), tooltip: '荧光笔'),
              ButtonSegment(value: NotebookTool.eraser, icon: Icon(Icons.cleaning_services, size: 18), tooltip: '橡皮（笔画擦除）'),
              ButtonSegment(value: NotebookTool.pan, icon: Icon(Icons.pan_tool, size: 18), tooltip: '移动画布（此模式不能画线）'),
            ],
            selected: {tool},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => onToolChanged(selection.first),
          ),
          // 颜色
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final swatch in kInkPalette)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    onTap: () => onColorChanged(swatch),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: swatch,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: swatch == color ? theme.colorScheme.primary : Colors.black26,
                          width: swatch == color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // 粗细
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final scale in kWidthScales)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    onTap: () => onWidthChanged(scale),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scale == widthScale ? theme.colorScheme.primary : Colors.black26,
                          width: scale == widthScale ? 2 : 1,
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: 4 + scale * 6,
                          height: 4 + scale * 6,
                          decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // 纸张模板
          PopupMenuButton<NotebookTemplate>(
            tooltip: '纸张模板',
            icon: const Icon(Icons.grid_on),
            onSelected: onTemplateChanged,
            initialValue: template,
            itemBuilder: (context) => [
              for (final item in NotebookTemplate.values)
                PopupMenuItem(value: item, child: Text('纸张：${item.label}')),
            ],
          ),
          IconButton(tooltip: '缩小', icon: const Icon(Icons.zoom_out), onPressed: onZoomOut),
          IconButton(tooltip: '重置缩放', icon: const Icon(Icons.fit_screen), onPressed: onZoomReset),
          IconButton(tooltip: '放大', icon: const Icon(Icons.zoom_in), onPressed: onZoomIn),
          const VerticalDivider(width: 12),
          IconButton(tooltip: '上一页', icon: const Icon(Icons.chevron_left), onPressed: canPrev ? onPrevPage : null),
          IconButton(tooltip: '下一页', icon: const Icon(Icons.chevron_right), onPressed: canNext ? onNextPage : null),
        ],
      ),
    );
  }
}


/// 诊断日志对话框：路径 + 末尾内容 + 复制 / 清空。
class _AppLogDialog extends StatefulWidget {
  const _AppLogDialog();

  @override
  State<_AppLogDialog> createState() => _AppLogDialogState();
}

class _AppLogDialogState extends State<_AppLogDialog> {
  Future<String?>? _future;

  @override
  void initState() {
    super.initState();
    _future = AppLog.readTail(400);
  }

  @override
  Widget build(BuildContext context) {
    final path = AppLog.path;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('诊断日志', style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Clipboard.setData(ClipboardData(text: path ?? '')),
                    child: const Text('复制路径'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final content = await AppLog.readTail(2000);
                      if (content != null) {
                        await Clipboard.setData(ClipboardData(text: content));
                      }
                    },
                    child: const Text('复制日志'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await AppLog.clear();
                      setState(() => _future = AppLog.readTail(400));
                    },
                    child: const Text('清空'),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  path ?? '日志不可用',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Divider(),
              Flexible(
                child: FutureBuilder<String?>(
                  future: _future,
                  builder: (context, snapshot) {
                    final content = snapshot.data;
                    if (content == null) {
                      return const Text('(空)');
                    }
                    return SingleChildScrollView(
                      child: SelectableText(
                        content,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.5),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
