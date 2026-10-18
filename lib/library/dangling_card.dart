/// 悬空引用卡片（设计文档 1.8.3）。
library;

import 'package:flutter/material.dart';

import '../models/mylibrary_models.dart';

/// 文件不可达时的引导卡片。
class DanglingCard extends StatelessWidget {
  const DanglingCard({required this.book, super.key});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_outlined),
                const SizedBox(width: 8),
                Expanded(child: Text('《${book.title}》文件尚未同步', style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text('${book.author} · ${book.sizeBytes} 字节 · 已读 ${(book.percentage * 100).round()}%', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            const Text('可能持有此文件的设备：'),
            ...book.heldBy.map((holder) => Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Text('• ${holder.clientId} · 最后在线 ${holder.lastSeen}', style: theme.textTheme.bodySmall),
                )),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(onPressed: () {}, child: const Text('向这些设备请求同步')),
                OutlinedButton(onPressed: () {}, child: const Text('从网盘其他位置扫描')),
                OutlinedButton(onPressed: () {}, child: const Text('仅保留元数据')),
                OutlinedButton(onPressed: () {}, child: const Text('从图书馆移除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
