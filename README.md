# ebook-studio — Flutter 跨平台版

设计文档**第三部分**的实现：独立应用，目标平台 macOS、Windows、iPad、Android 平板。

## 为什么是 Flutter 而不是 Tauri（设计文档 3.1）

| 维度 | 说明 |
|---|---|
| UI 一致性 | Skia 自绘引擎，四端渲染一致，60fps+ 无卡顿 |
| 手写笔支持 | `scribe_canvas` / `fluera_canvas` 提供压感、倾斜、手掌拒绝 |
| 桌面就绪 | Flutter 3.38 起 Windows / macOS / Linux 全部 Stable |
| PDF 性能 | 通过 FFI 调用 PDFium，原生级性能 |

Tauri 依赖系统 WebView，平板上手写笔延迟和压感支持不如 Flutter 原生 Canvas。
阅读和手写是**延迟敏感型**操作，这一点是决定性的。

## 目录（对齐设计文档 3.7）

```
ebook-studio/
├── lib/
│   ├── main.dart                    # 入口
│   ├── app.dart                     # 外壳 + 路由（按宽度切换桌面/平板布局）
│   ├── models/
│   │   └── mylibrary_models.dart    # 数据契约的 Dart 镜像（与 TS 版逐字段一致）
│   ├── engines/
│   │   └── book_engine.dart         # 统一 BookEngine 接口 + 四种实现
│   ├── reader/
│   │   └── reader_page.dart         # 阅读器界面（翻页/进度/位置保存）
│   ├── library/
│   │   ├── library_page.dart        # 图书馆界面
│   │   ├── catalog.dart             # 本地导入：扫描目录 → books/{书名}/
│   │   └── dangling_card.dart       # 悬空引用卡片（设计文档 1.8.3）
│   ├── storage/
│   │   ├── my_library_store.dart    # MyLibrary 本地访问层
│   │   ├── remote_provider.dart     # RemoteProvider 抽象 + WebDAV/百度适配器
│   │   └── sync.dart                # 版本对比 / 冲突合并 / 删除语义
│   ├── features/
│   │   ├── annotation/
│   │   │   ├── ink_canvas.dart      # CustomPainter 手写层（矢量笔迹）
│   │   │   └── annotation_panel.dart
│   │   ├── translation/
│   │   │   └── translate_page.dart  # 直连翻译 API，不依赖 dsh
│   │   └── recorder/
│   │       └── record_page.dart     # 屏幕录制入口（Platform Channel）
│   └── ui/
│       ├── desktop/desktop_layout.dart
│       └── tablet/tablet_layout.dart
├── ios/Runner/ReplayKitBridge.swift       # iPad 录制桥接
├── android/app/src/main/MediaProjectionBridge.kt  # Android 录制桥接
├── test/mylibrary_test.dart               # 数据契约 + 同步 + 跨端互通测试
└── pubspec.yaml
```

## 技术栈（设计文档 3.2）

| 层次 | 选型 |
|---|---|
| 框架 | Flutter（Dart） |
| PDF 渲染 | PDFium（FFI） |
| EPUB 渲染 | flutter_epub_viewer |
| Markdown | flutter_markdown |
| TXT 分页 | 自研分页器 |
| 手写标注 | 自研 CustomPainter + 矢量笔迹 |
| 屏幕录制（桌面） | desktop_screen_recorder |
| 屏幕录制（平板） | ReplayKit（iOS）/ MediaProjection（Android） |
| 本地数据库 | SQLite（drift / sqflite） |
| 网盘协议 | WebDAV + 百度网盘适配器 |
| 状态管理 | Riverpod |

## 快速开始

```bash
# 本机未安装 Flutter SDK 时先装（需要 >= 3.38）
# 见 https://docs.flutter.dev/get-started/install

cd ebook-studio
flutter pub get
flutter run -d macos        # 桌面
flutter run -d "iPad Pro"   # 平板
flutter test                # 数据契约测试
flutter analyze             # 静态检查
```

## 与 dsh 扩展版的数据互通（设计文档 4.2）

两个软件读写**同一份** `MyLibrary/` 目录：

- **换设备续读**：Mac 上 dsh 版读到 35%，iPad 上打开同一本书，从 35% 继续
- **跨端批注**：iPad 上手写 PDF 批注（PDFium 原生注释），Mac 上 dsh 版打开可见墨迹
- **Wiki 互通**：任一软件创建 Wiki 页面，另一端打开即可见
- **录课回看**：iPad 录制的视频，桌面端可播放，元数据正确
- **图书馆同步**：Mac 上导入新书，iPad 图书馆自动更新（元数据同步）

## 已验证（真实 Flutter 3.35.5 / Dart 3.9.2 环境）

```
flutter analyze   → 0 error / 0 warning（仅 7 条 prefer_const_constructors info）
flutter test      → 50 个测试全部通过
```

测试覆盖：
- Schema 兼容性（主版本/次版本/非法版本）
- 版本对比（download / none / upload）
- 冲突合并（书籍并集、字段并集、reading_position 决胜、held_by 排序、sync_state 择优、manual 策略未解决冲突）
- 同步请求队列、删除语义（四种）
- Wiki 解析（含 YAML 块状列表）、序列化往返、图谱出链反链
- 扫描导入、笔记边车、录课元数据、迁移备份
- 引擎（工厂分派、TXT 分页、Markdown 目录、边车路径推导）
- **跨端数据互通**：两个客户端（dsh-macos / flutter-ipad）读写同一份 MyLibrary

### 安装 Flutter SDK 时的环境变量

macOS 的 TCC 隐私保护会拦截对家目录的写入（`~/dev`、`~/Downloads` 都是
`Operation not permitted`），Flutter 又要写 `$HOME/.dart-tool` 和
`~/.config/flutter`，因此必须重定向：

```bash
export HOME=$PWD/../.toolchain/home
export XDG_CONFIG_HOME=$PWD/../.toolchain/config
export PUB_CACHE=$PWD/../.toolchain/pub-cache
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PATH=$PWD/../.toolchain/flutter/bin:$PATH
```

