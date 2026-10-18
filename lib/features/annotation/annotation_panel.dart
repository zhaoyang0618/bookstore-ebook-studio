/// 批注面板（设计文档 1.5）。
library;

import 'package:flutter/material.dart';

import '../../storage/my_library_store.dart';

/// 批注列表面板。
class AnnotationPanel extends StatelessWidget {
  const AnnotationPanel({required this.annotations, super.key});

  final List<Annotation> annotations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text('批注（${annotations.length}）', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Expanded(
              child: annotations.isEmpty
                  ? const Center(child: Text('还没有批注。选中文本可以高亮，打开手写层可以绘制墨迹。'))
                  : ListView.separated(
                      controller: scrollController,
                      itemCount: annotations.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) => _AnnotationTile(annotation: annotations[index]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// 一条批注。
class _AnnotationTile extends StatelessWidget {
  const _AnnotationTile({required this.annotation});

  final Annotation annotation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (annotation.type) {
      'highlight' => Icons.format_color_text,
      'note' => Icons.note_outlined,
      'ink' => Icons.gesture,
      _ => Icons.bookmark_outline,
    };
    return ListTile(
      leading: Icon(icon),
      title: Text(annotation.text ?? annotation.note ?? '墨迹批注', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${annotation.updatedAt}\n锚点：${_describeAnchor(annotation.anchor)}', style: theme.textTheme.labelSmall),
      isThreeLine: true,
    );
  }

  /// 描述锚点（设计文档 1.5 锚定方式）。
  String _describeAnchor(Map<String, dynamic> anchor) {
    final type = anchor['type'];
    return switch (type) {
      'epubcfi' => 'EPUB CFI：${anchor['value']}',
      'line_range' => 'Markdown 行 ${anchor['start_line']}-${anchor['end_line']}',
      'char_offset' => 'TXT 偏移 ${anchor['offset']}',
      'ink' => 'PDF 第 ${anchor['page']} 页墨迹',
      _ => '未知锚点',
    };
  }
}
