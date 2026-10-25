/// 笔记本图书馆（GoodNotes / Notability 风格）。
///
/// 目录选择：配置了 MyLibrary 时笔记本存 `MyLibrary/notebooks/`
/// （随图书馆同步）；否则用应用文档目录 `notebooks/`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../library/library_page.dart';
import '../../storage/my_library_store.dart';
import '../../ui/fullscreen.dart';
import 'notebook_editor.dart';
import 'notebook_store.dart';

/// 笔记本图书馆页。
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  NotebookStore? _store;
  String? _storeKey;
  List<Notebook> _notebooks = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  /// 笔记本目录：MyLibrary 下的可配置子文件夹（settings.json），
  /// 未配置图书馆时退回应用文档目录 `notebooks/`。
  Future<String> _resolveDir() async {
    final root = ref.read(libraryRootProvider);
    if (root == null || root.isEmpty) {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'notebooks');
    }
    final settings = MyLibraryStore(root, clientId: 'flutter-app-client').readSettings();
    return p.join(root, settings.notebooksDir);
  }

  Future<void> _reload() async {
    final dir = await _resolveDir();
    final root = ref.read(libraryRootProvider);
    final key = root ?? dir;
    if (_store == null || _storeKey != key) {
      _store = NotebookStore(dir);
      _storeKey = key;
    }
    if (!mounted) return;
    setState(() => _notebooks = _store!.list());
  }

  /// 设置笔记本文件夹（相对 MyLibrary 根；随图书馆一起同步）。
  Future<void> _openFolderSettings() async {
    final root = ref.read(libraryRootProvider);
    if (root == null || root.isEmpty || _store == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未配置图书馆 —— 笔记本保存在应用文档目录，配置图书馆后才能自定义文件夹并同步')),
      );
      return;
    }
    final settings = MyLibraryStore(root, clientId: 'flutter-app-client').readSettings();
    final controller = TextEditingController(text: settings.notebooksDir);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('笔记本文件夹'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('相对 MyLibrary 根目录的子文件夹（随图书馆同步到网盘）：\n$root',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '子文件夹', hintText: 'notebooks'),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            const SizedBox(height: 8),
            Text('更改后，旧文件夹里的笔记本不会自动移动。',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    final sanitized = sanitizeRelativeDir(result);
    if (sanitized == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件夹名不可用（不能为空、绝对路径或包含 ..）')),
        );
      }
      return;
    }
    MyLibraryStore(root, clientId: 'flutter-app-client')
        .writeSettings(LibrarySettings(notebooksDir: sanitized));
    _store = null; // 强制按新目录重建
    await _reload();
  }

  Future<void> _createNotebook() async {
    final store = _store;
    if (store == null) return;
    final draft = await showDialog<(String, int, NotebookTemplate)>(
      context: context,
      builder: (context) => const _NewNotebookDialog(),
    );
    if (draft == null) return;
    final notebook = store.create(title: draft.$1, coverColor: draft.$2, template: draft.$3);
    await _reload();
    if (!mounted) return;
    await _open(notebook);
  }

  Future<void> _open(Notebook notebook) async {
    final store = _store;
    if (store == null) return;
    final fresh = store.read(notebook.id) ?? notebook;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NotebookEditorPage(
          notebook: fresh,
          store: store,
          onSaved: (_) => unawaited(_reload()),
        ),
      ),
    );
    // 关闭编辑器后元数据（updated_at / 页数）可能变了
    await _reload();
  }

  Future<void> _renameNotebook(Notebook notebook) async {
    final store = _store;
    if (store == null) return;
    final controller = TextEditingController(text: notebook.title);
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
    if (title == null || title.trim().isEmpty) return;
    store.save(notebook.copyWith(title: title.trim()));
    await _reload();
  }

  Future<void> _deleteNotebook(Notebook notebook) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除笔记本？'),
        content: Text('「${notebook.title}」的全部 ${notebook.pages.length} 页会一并删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    store.delete(notebook.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    // 换了图书馆目录 → 笔记本目录跟着变
    ref.listen(libraryRootProvider, (_, __) => unawaited(_reload()));
    final store = _store;

    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记'),
        actions: [
          IconButton(
            tooltip: '笔记本文件夹',
            icon: const Icon(Icons.folder_open),
            onPressed: _openFolderSettings,
          ),
          IconButton(
            tooltip: '新建笔记本',
            icon: const Icon(Icons.note_add),
            onPressed: _createNotebook,
          ),
          const FullscreenAppBarButton(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNotebook,
        icon: const Icon(Icons.add),
        label: const Text('新建笔记本'),
      ),
      body: store == null
          ? const Center(child: CircularProgressIndicator())
          : _notebooks.isEmpty
              ? _EmptyState(onCreate: _createNotebook, dir: store.dir)
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 230,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: _notebooks.length,
                  itemBuilder: (context, index) {
                    final notebook = _notebooks[index];
                    return _NotebookCard(
                      notebook: notebook,
                      onOpen: () => _open(notebook),
                      onRename: () => _renameNotebook(notebook),
                      onDelete: () => _deleteNotebook(notebook),
                    );
                  },
                ),
    );
  }
}

/// 笔记本卡片：彩色封面 + 标题 + 页数/时间。
class _NotebookCard extends StatelessWidget {
  const _NotebookCard({
    required this.notebook,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final Notebook notebook;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cover = Color(notebook.coverColor);
    final updated = notebook.updatedAt.isEmpty ? '' : notebook.updatedAt.substring(0, 10);
    return InkWell(
      onTap: onOpen,
      onLongPress: () => _showMenu(context),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: cover,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(color: cover.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 封面「书脊」装饰
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: Text(
                  notebook.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  Text('${notebook.pages.length} 页',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  const Spacer(),
                  Text(updated, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(context);
                onRename();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除笔记本'),
              onTap: () {
                Navigator.pop(context);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 空状态。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate, required this.dir});

  final VoidCallback onCreate;
  final String dir;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.draw_outlined, size: 56, color: Theme.of(context).hintColor),
          const SizedBox(height: 12),
          Text('还没有笔记本', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('点击「新建笔记本」开始手写\n保存位置：$dir',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 新建笔记本对话框：标题 + 封面色 + 纸张模板。
class _NewNotebookDialog extends StatefulWidget {
  const _NewNotebookDialog();

  @override
  State<_NewNotebookDialog> createState() => _NewNotebookDialogState();
}

class _NewNotebookDialogState extends State<_NewNotebookDialog> {
  final _titleController = TextEditingController();
  int _cover = kNotebookCoverColors.first.toARGB32();
  NotebookTemplate _template = NotebookTemplate.ruled;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建笔记本'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '标题', hintText: '例如：读书笔记'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text('封面', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                for (final color in kNotebookCoverColors)
                  InkWell(
                    onTap: () => setState(() => _cover = color.toARGB32()),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _cover == color.toARGB32()
                              ? Theme.of(context).colorScheme.primary
                              : Colors.black26,
                          width: _cover == color.toARGB32() ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('纸张', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            SegmentedButton<NotebookTemplate>(
              segments: [
                for (final item in NotebookTemplate.values)
                  ButtonSegment(value: item, label: Text(item.label)),
              ],
              selected: {_template},
              onSelectionChanged: (selection) => setState(() => _template = selection.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }

  void _submit() {
    Navigator.pop(context, (_titleController.text.trim(), _cover, _template));
  }
}
