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

## PDF 原生注释写入（设计文档 3.3 / 4.2）

手写墨迹会同时保存两份：

| 位置 | 用途 |
|---|---|
| 边车 `.notes.json` | App 的工作副本（含 id / 时间戳等 PDF 注释放不下的元数据） |
| **PDF 文件内的 `/Ink` 注释** | 让 dsh 版（PDF.js）、Acrobat、预览也能看到 |

写入方式：阅读器里点 **「写入 PDF 原生注释」**（PDF 格式下才出现）。
它会**直接修改原 PDF**，因此写入前会自动备份，且整个流程失败不会碰原文件。

### 技术选型

要把墨迹写成 PDF 标准注释对象，可用方案对比：

| 方案 | 结论 |
|---|---|
| pdfrx 自带的 PDFium 绑定 | `FPDFAnnot_*` 与保存 API 均为**内部私有**，未导出，用不了 |
| `syncfusion_flutter_pdf` | 有低层对象模型，但**没有墨迹注释类型**，且是商业许可 |
| 复用 `mylibrary` 的 TS 实现 | 需要用户装 Node，违背「软件不装外部工具」 |
| **自研纯 Dart 增量更新** | 无新依赖、可本地完整测试、五平台一致 ← 采用 |

### 实现范围

`lib/pdf/` 三个模块：

- `pdf_syntax.dart` — PDF 对象模型、词法/语法分析、序列化（含中文 UTF-16BE hex）
- `pdf_reader.dart` — 交叉引用（**经典表 + xref 流**）、**对象流**、页面树、增量写入器
- `pdf_ink_export.dart` — 构造 `/Ink` 注释、安全写回

写入采用**增量更新**：只在文件尾追加新对象 + 新 xref 表 + 新 trailer
（用 `/Prev` 指向原交叉引用），不重写原内容 —— 这是 PDF 规范明确支持的更新方式。

处理的难点：`2.pdf`（LaTeX 生成，PDF 1.7）的页面对象**全部压缩在对象流里**，
且用 xref 流而非经典表，MediaBox 还要从 4 层祖先继承。

### 验证

18 个单元测试 + 外部工具双重验证：

```
pdfinfo  → Pages: 338        （结构完好，无语法错误）
pypdf    → 第 1 页 34 条注释，其中 Ink 2 条
           NM=ink-中文测试-1  T=ebook studio 中文作者   ← 中文正确
           InkList=[[100, 741.89, 200, 691.89, 300, 721.89]]  ← y 已翻转
           Rect=[98, 689.89, 302, 743.89]  C=[0.898, 0.2235, 0.2078]
```

## 多平台构建（GitHub Actions）

本地只有 Command Line Tools 没有 Xcode，macOS/iOS 构建交给 GitHub Actions。
`.github/workflows/build.yml` 覆盖五个平台：

| 平台 | Runner | 产物 | 状态 |
|---|---|---|---|
| macOS | `macos-14` | `ebook_studio-macos.zip` (25.2 MB) | ✅ |
| Windows | `windows-2022` | `ebook_studio-windows.zip` (17.1 MB) | ✅ |
| Linux | `ubuntu-22.04` | `ebook_studio-linux.tar.gz` (23.2 MB) | ✅ |
| iOS | `macos-14` | 未签名 `.app`（真机需自签） | ✅ |
| Android | `ubuntu-latest` | `app-release.apk` | ✅ |

### 下载（打 tag 自动发布到 Release）

打 `v*` tag 时 `release` 作业会把各平台产物挂到 GitHub Release。
Release 资产**公开可下载**（Actions 的 artifact 反而需要登录），方便直接分发：

**<https://github.com/zhaoyang0618/bookstore-ebook-studio/releases>**

下载地址用 `releases/latest/download/<文件名>` 形式，
**永远指向最新版本**，不必随发版改文档：

| 文件 | 链接 |
|---|---|
| macOS (arm64) | [ebook_studio-macos.zip](https://github.com/zhaoyang0618/bookstore-ebook-studio/releases/latest/download/ebook_studio-macos.zip) |
| Windows | [ebook_studio-windows.zip](https://github.com/zhaoyang0618/bookstore-ebook-studio/releases/latest/download/ebook_studio-windows.zip) |
| Linux | [ebook_studio-linux.tar.gz](https://github.com/zhaoyang0618/bookstore-ebook-studio/releases/latest/download/ebook_studio-linux.tar.gz) |
| Android | [app-release.apk](https://github.com/zhaoyang0618/bookstore-ebook-studio/releases/latest/download/app-release.apk) |
| iOS（未签名） | [ebook_studio-ios-unsigned.zip](https://github.com/zhaoyang0618/bookstore-ebook-studio/releases/latest/download/ebook_studio-ios-unsigned.zip) |

> 需要固定版本时，把 `latest` 换成具体 tag，例如
> `/releases/download/v0.5.1/ebook_studio-macos.zip`。

#### 运行未签名的 macOS 应用

产物没有 Apple 开发者签名，Gatekeeper 会拦截。首次打开需要：

```bash
# 方式一：解除隔离标记（推荐，一次就好）
xattr -dr com.apple.quarantine /path/to/ebook_studio.app

# 方式二：右键点 app → 打开 → 在弹窗里再点「打开」
```

> macOS 产物是 **arm64**（构建用的 `macos-14` runner 是 Apple Silicon）。
> Intel Mac 需另配 `macos-13` runner 或构建 universal binary。

#### 试用

应用启动后点 **「直接打开一本书…」**，选任意 EPUB / PDF / TXT / Markdown 即可阅读，
不需要先配置 MyLibrary 目录。

### 踩过的两个 CI 坑

**1. Windows 必须用 `windows-2022`，不能用 `windows-latest`**

失败信息：
```
CMake Error at CMakeLists.txt:3 (project):
  Generator Visual Studio 16 2019 could not find any instance of Visual Studio.
```

原因：Flutter 3.35.5 的 `visual_studio.dart` 生成器映射只有
`17 => 'Visual Studio 17 2022'`，其余落到默认 `'Visual Studio 16 2019'`。
`windows-latest` 已升级到 **Visual Studio 18**，映射不到 17 → 请求 VS 2019 → 失败。

**2. `epub_viewer` 会让 Android 构建失败**

失败信息：
```
A problem occurred configuring project ':epub_viewer'.
> Namespace not specified. Specify a namespace in the module's build file:
  .../epub_viewer-0.2.5/android/build.gradle
```

该插件 2022 年起停止维护（SDK 约束还是 `<3.0.0`），缺少 AGP 8+ 必需的
`namespace` 声明，Gradle 配置阶段直接失败。

### EPUB 渲染选型（待定）

两个候选都有硬伤，因此暂未引入依赖，`EpubEngine` 保持占位实现：

| 候选 | 问题 |
|---|---|
| `epub_viewer` | 2022 年停更；缺 `namespace`，Android 构建失败（已实测） |
| `flutter_epub_viewer` | 依赖 `flutter_inappwebview`；平台仅 android/ios/macos/web，**不含 Windows/Linux** |

而设计文档要求 Flutter 版覆盖 macOS / Windows / iPad / Android。
后续可考虑与 dsh 版一致的方案：WebView + foliate-js，这样两端渲染逻辑也能统一。

## 已验证（真实 Flutter 3.35.5 / Dart 3.9.2 环境）

```
flutter analyze   → No issues found!
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

