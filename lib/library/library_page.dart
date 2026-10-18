/// 图书馆状态与界面（设计文档 3.4）。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/mylibrary_models.dart';
import '../routes.dart';
import '../storage/my_library_store.dart';
import 'dangling_card.dart';

/// MyLibrary 根目录（默认放在应用文档目录下）。
final libraryRootProvider = StateProvider<String?>((ref) => null);

/// 已加载的 library.json。
final libraryProvider = StateProvider<Library?>((ref) => null);

/// 悬空引用提示（设计文档 1.8.3）。
final danglingBookProvider = StateProvider<Book?>((ref) => null);

/// 直接打开一个本地文件（不经过 MyLibrary 导入流程）。
///
/// 用途：让用户挑选任意 EPUB / PDF / TXT / Markdown 立刻阅读，
/// 不需要先配置图书馆目录。也让「下载后试一下」这件事变得简单。
final standaloneFileProvider = StateProvider<String?>((ref) => null);

/// 弹出文件选择器并打开选中的书。
Future<void> pickAndOpenFile(WidgetRef ref) async {
  const typeGroup = XTypeGroup(
    label: '电子书',
    extensions: <String>['epub', 'pdf', 'txt', 'md', 'markdown'],
  );
  final file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
  if (file == null) return;
  ref.read(standaloneFileProvider.notifier).state = file.path;
  ref.read(appRouteProvider.notifier).state = AppRoute.reader;
}

/// 打开一个 MyLibrary 目录。
Future<void> openLibrary(WidgetRef ref, String root) async {
  final store = MyLibraryStore(root, clientId: 'flutter-app-client');
  if (!Directory(root).existsSync()) store.init();
  final manifest = store.readManifest();
  final platform = _detectPlatform();
  store.writeManifest(manifest.touchClient(
    ManifestClient(id: 'flutter-app-client', type: ClientType.flutterApp, platform: platform, lastSeen: DateTime.now().toUtc().toIso8601String()),
    DateTime.now().toUtc().toIso8601String(),
  ));
  final library = store.readLibrary();
  ref.read(libraryRootProvider.notifier).state = root;
  ref.read(libraryProvider.notifier).state = library;
  ref.read(danglingBookProvider.notifier).state = _findDangling(library, 'flutter-app-client');
}

/// 默认 MyLibrary 位置：应用文档目录下的 MyLibrary。
Future<String> defaultLibraryRoot() async {
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, 'MyLibrary');
}

ClientPlatform _detectPlatform() {
  if (Platform.isIOS) return ClientPlatform.ipad;
  if (Platform.isAndroid) return ClientPlatform.android;
  if (Platform.isMacOS) return ClientPlatform.macos;
  if (Platform.isWindows) return ClientPlatform.windows;
  if (Platform.isLinux) return ClientPlatform.linux;
  return ClientPlatform.web;
}

/// 找出文件不可达的书（设计文档 1.8.3 悬空引用）。
Book? _findDangling(Library library, String clientId) {
  for (final book in library.books) {
    final heldByMe = book.heldBy.any((h) => h.clientId == clientId);
    if (book.syncState.file == SyncState.missing) return book;
    if (!heldByMe && book.syncState.file == SyncState.localOnly) return book;
  }
  return null;
}

/// 图书馆界面。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final root = ref.watch(libraryRootProvider);
    final dangling = ref.watch(danglingBookProvider);

    if (library == null || root == null) {
      return _EmptyLibrary(onOpen: (path) => openLibrary(ref, path), ref: ref);
    }

    final groups = _groupBooks(library.books);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的图书馆'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: Text('v${library.version} · ${library.books.length} 本', style: Theme.of(context).textTheme.bodySmall)),
          ),
          IconButton(
            tooltip: '直接打开一本书',
            icon: const Icon(Icons.folder_open),
            onPressed: () => pickAndOpenFile(ref),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => openLibrary(ref, root),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (dangling != null) DanglingCard(book: dangling),
          for (final group in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(group.key, style: Theme.of(context).textTheme.titleMedium),
            ),
            GridView.count(
              crossAxisCount: MediaQuery.sizeOf(context).width >= 900 ? 5 : 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.62,
              children: group.books.map((book) => BookCard(book: book, root: root)).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

/// 空图书馆提示。
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onOpen, required this.ref});

  final void Function(String path) onOpen;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的图书馆')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.library_books_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('还没有打开图书馆'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async => onOpen(await defaultLibraryRoot()),
              icon: const Icon(Icons.library_books),
              label: const Text('打开默认图书馆'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => pickAndOpenFile(ref),
              icon: const Icon(Icons.folder_open),
              label: const Text('直接打开一本书…'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按收藏夹分组。
List<({String key, List<Book> books})> _groupBooks(List<Book> books) {
  final groups = <String, List<Book>>{};
  for (final book in books) {
    final keys = book.collections.isNotEmpty ? book.collections : ['未分类'];
    for (final key in keys) {
      groups.putIfAbsent(key, () => []).add(book);
    }
  }
  return groups.entries.map((entry) => (key: entry.key, books: entry.value)).toList();
}

/// 书籍卡片。
class BookCard extends StatelessWidget {
  const BookCard({required this.book, required this.root, super.key});

  final Book book;
  final String root;

  @override
  Widget build(BuildContext context) {
    final cover = book.coverPath;
    final coverFile = cover != null ? File(p.join(root, cover)) : null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openReader(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: coverFile != null && coverFile.existsSync()
                  ? Image.file(coverFile, fit: BoxFit.cover, width: double.infinity)
                  : Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Center(child: Text(book.title.substring(0, 1), style: Theme.of(context).textTheme.headlineLarge)),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                  Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: book.percentage, minHeight: 4),
                  ),
                  const SizedBox(height: 4),
                  Text('${(book.percentage * 100).round()}% · ${book.format.wire.toUpperCase()}', style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: [
                      SyncBadge(label: '元数据', state: book.syncState.metadata),
                      SyncBadge(label: '文件', state: book.syncState.file),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openReader(BuildContext context) {
    final provider = ProviderScope.containerOf(context, listen: false);
    provider.read(selectedBookProvider.notifier).state = book;
    provider.read(appRouteProvider.notifier).state = AppRoute.reader;
  }
}

/// 同步状态徽章。
class SyncBadge extends StatelessWidget {
  const SyncBadge({required this.label, required this.state, super.key});

  final String label;
  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      SyncState.synced => (Icons.cloud_done, Colors.green),
      SyncState.localOnly => (Icons.computer, Colors.orange),
      SyncState.partial => (Icons.cloud_sync, Colors.blue),
      SyncState.missing => (Icons.error_outline, Colors.red),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// 当前选中的书（供阅读器使用）。
final selectedBookProvider = StateProvider<Book?>((ref) => null);
