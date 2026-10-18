/// EPUB 渲染引擎：WebView + foliate-js（设计文档 3.2 / 3.3）。
///
/// ## 为什么用 WebView + foliate-js 而不是现成插件
///
/// | 方案 | 问题 |
/// |---|---|
/// | `epub_viewer` | 2022 年停更，`android/build.gradle` 缺 AGP 8+ 必需的 `namespace`，构建直接失败 |
/// | `flutter_epub_viewer` | 依赖 `flutter_inappwebview` 且平台声明仅 android/ios/macos/web，**不含 Windows/Linux** |
///
/// 而 dsh 扩展版（Web 端）本来就用 foliate-js 渲染 EPUB。
/// 两端共用同一渲染引擎，翻页/CFI/批注行为天然一致——这是设计文档 4.2
/// 「跨端批注」「换设备续读」能对上的前提。
///
/// ## 通信方式
///
/// Dart ←→ JS 通过 `flutter_inappwebview` 的 JavaScript handler 双向通信：
/// - JS → Dart：`window.flutter_inappwebview.callHandler('epubEvent', json)`
/// - Dart → JS：`controller.evaluateJavascript(source: 'window.epubApi.xxx()')`
///
/// ## 已知限制
///
/// `flutter_inappwebview` 没有 Linux 实现，因此 **Linux 上 EPUB 不可渲染**
/// （其它格式不受影响）。详见 README。
///
/// @module ebook-studio/engines/epub_webview
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 阅读位置（对应 foliate 的 relocate 事件）。
class EpubLocation {
  const EpubLocation({required this.cfi, required this.fraction, this.tocLabel});

  /// EPUB CFI（设计文档 1.5 的锚定方式）。
  final String cfi;

  /// 全书进度 0 ~ 1。
  final double fraction;

  /// 当前章节标题。
  final String? tocLabel;

  @override
  String toString() => 'EpubLocation(cfi: $cfi, fraction: $fraction)';
}

/// 桥接就绪状态。
enum EpubBridgeState { loading, ready, opened, failed }

/// WebView 与 foliate 之间的控制器。
///
/// 生命周期：widget 创建 → `attach` 到 WebView → `openBytes` 打开书 →
/// 之后翻页/跳转都经过这里。
class EpubController extends ChangeNotifier {
  InAppWebViewController? _web;

  /// 脚本桥是否已就绪（viewer.html 加载完成）。
  bool bridgeReady = false;

  /// 当前状态。
  EpubBridgeState state = EpubBridgeState.loading;

  /// 最近一次错误信息（会在界面上显示，便于诊断）。
  String? lastError;

  /// 书籍元信息。
  String? bookTitle;
  int sectionCount = 0;

  /// 最近一次阅读位置。
  EpubLocation? location;

  /// 待打开的数据（桥未就绪时先缓存）。
  Uint8List? _pendingBytes;
  String? _pendingCfi;

  /// 位置变化流。
  final _locationController = StreamController<EpubLocation>.broadcast();
  Stream<EpubLocation> get onLocation => _locationController.stream;

  /// 由 widget 在 `onWebViewCreated` 时调用。
  void attach(InAppWebViewController web) {
    _web = web;
  }

  /// 处理来自 JS 的事件。
  void handleEvent(String raw) {
    Map<String, dynamic> event;
    try {
      event = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (event['type']) {
      case 'bridge-ready':
        bridgeReady = true;
        // 桥就绪前若已请求打开，现在补上
        final bytes = _pendingBytes;
        if (bytes != null) {
          _pendingBytes = null;
          final cfi = _pendingCfi;
          _pendingCfi = null;
          unawaited(openBytes(bytes, initialCfi: cfi));
        } else {
          state = EpubBridgeState.ready;
          notifyListeners();
        }
      case 'opened':
        state = EpubBridgeState.opened;
        bookTitle = event['title'] as String?;
        sectionCount = (event['sections'] as num?)?.toInt() ?? 0;
        notifyListeners();
      case 'relocate':
        final cfi = event['cfi'] as String?;
        final fraction = (event['fraction'] as num?)?.toDouble();
        if (cfi != null && fraction != null) {
          location = EpubLocation(
            cfi: cfi,
            fraction: fraction,
            tocLabel: event['tocLabel'] as String?,
          );
          _locationController.add(location!);
          notifyListeners();
        }
      case 'error':
        state = EpubBridgeState.failed;
        lastError = event['message'] as String? ?? '未知错误';
        notifyListeners();
    }
  }

  /// 打开一本 EPUB 的字节内容。
  ///
  /// 用 base64 经 JS 注入，避免 `file://` 跨目录读取被 WebKit 拦截。
  /// 代价是传输体积约为原文件 1.33 倍——对常见电子书（几 MB）可以接受。
  Future<void> openBytes(Uint8List bytes, {String? initialCfi}) async {
    final web = _web;
    if (web == null) {
      // WebView 还没创建，先缓存
      _pendingBytes = bytes;
      _pendingCfi = initialCfi;
      return;
    }
    if (!bridgeReady) {
      _pendingBytes = bytes;
      _pendingCfi = initialCfi;
      return;
    }
    state = EpubBridgeState.loading;
    lastError = null;
    notifyListeners();

    final base64Bytes = base64Encode(bytes);
    final cfiArg = initialCfi == null ? 'null' : jsonEncode(initialCfi);
    // 用 JSON 字符串字面量承载 base64，避免引号/转义问题
    await web.evaluateJavascript(
      source: 'window.epubApi.openBase64(${jsonEncode(base64Bytes)}, $cfiArg);',
    );
  }

  /// 由 widget 层报告错误（WebView 加载失败等）。
  void reportError(String message) {
    state = EpubBridgeState.failed;
    lastError = message;
    notifyListeners();
  }

  /// 下一页。
  Future<void> next() async => _web?.evaluateJavascript(source: 'window.epubApi.next();');

  /// 上一页。
  Future<void> prev() async => _web?.evaluateJavascript(source: 'window.epubApi.prev();');

  /// 跳到指定 CFI。
  Future<void> goTo(String cfi) async =>
      _web?.evaluateJavascript(source: 'window.epubApi.goTo(${jsonEncode(cfi)});');

  @override
  void dispose() {
    unawaited(_locationController.close());
    super.dispose();
  }
}

/// 承载 foliate-js 的 WebView。
class EpubWebView extends StatefulWidget {
  const EpubWebView({required this.controller, super.key});

  final EpubController controller;

  @override
  State<EpubWebView> createState() => _EpubWebViewState();
}

class _EpubWebViewState extends State<EpubWebView> {
  /// 阅读器页面路径（Flutter 资源）。
  static const String _viewerAsset = 'assets/foliate/viewer.html';

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialFile: _viewerAsset,
      initialSettings: InAppWebViewSettings(
        // foliate-js 是 ES module，从 file:// 加载需要放开文件访问限制
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        javaScriptEnabled: true,
        transparentBackground: true,
        // 阅读场景：禁掉缩放与滚动条，交给 foliate 自己处理分页
        supportZoom: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        disableVerticalScroll: true,
        disableHorizontalScroll: true,
        // 本地内容不需要网络
        useShouldOverrideUrlLoading: false,
      ),
      onWebViewCreated: (web) {
        widget.controller.attach(web);
        web.addJavaScriptHandler(
          handlerName: 'epubEvent',
          callback: (args) {
            final payload = args.isNotEmpty ? args.first : null;
            if (payload is String) widget.controller.handleEvent(payload);
            return null;
          },
        );
      },
      onConsoleMessage: (controller, message) {
        // 便于诊断：把 WebView 控制台输出转到 Flutter 日志
        debugPrint('[epub-webview] ${message.message}');
      },
      onReceivedError: (controller, request, error) {
        // 只报告主文档的加载失败；子资源（图片等）失败不阻断阅读
        if (request.isForMainFrame ?? false) {
          widget.controller.reportError('WebView 加载失败：${error.description}');
        }
      },
    );
  }
}
