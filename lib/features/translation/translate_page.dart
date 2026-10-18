/// 翻译（设计文档 3.6）。
///
/// Flutter 端直接调用翻译 API（OpenAI 兼容 / DeepL / Ollama），**不依赖 dsh**。
/// 划词翻译使用 `SelectableText` 或自定义选择层。
library;

import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// 翻译服务配置。
class TranslateConfig {
  const TranslateConfig({required this.baseUrl, required this.model, this.apiKey = '', this.targetLang = 'zh'});

  final String baseUrl;
  final String model;
  final String apiKey;
  final String targetLang;

  /// 默认配置：DeepSeek 官方接口（用户可在界面里改）。
  static const TranslateConfig defaults = TranslateConfig(baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat');
}

/// 翻译配置。
final translateConfigProvider = StateProvider<TranslateConfig>((ref) => TranslateConfig.defaults);

/// 翻译结果（null 表示未翻译）。
final translateResultProvider = StateProvider<String?>((ref) => null);

/// 是否正在翻译。
final translatingProvider = StateProvider<bool>((ref) => false);

/// 构造翻译用的 system prompt（与 dsh 版一致）。
String buildTranslatePrompt({required String targetLang, String sourceLang = 'auto', String context = ''}) {
  final parts = <String>[
    '你是一名专业的文学翻译。请把用户提供的文本翻译成$targetLang。',
    '要求：',
    '1. 只输出译文本身，不要解释、不要加引号、不要标注语言。',
    '2. 保留原文的段落结构与标点风格。',
    '3. 专有名词首次出现时可在括号内保留原文。',
  ];
  if (sourceLang.isNotEmpty && sourceLang != 'auto') {
    parts.insert(1, '源语言是$sourceLang。');
  }
  if (context.trim().isNotEmpty) {
    parts.add('\n上下文（书名 / 章节 / 前后文，仅供理解，不要翻译）：\n${context.trim()}');
  }
  return parts.join('\n');
}

/// 调用 OpenAI 兼容接口做翻译。
Future<String> translateText({
  required TranslateConfig config,
  required String text,
  String sourceLang = 'auto',
  String context = '',
  http.Client? client,
}) async {
  if (text.trim().isEmpty) throw ArgumentError('待翻译文本不能为空');
  final httpClient = client ?? http.Client();
  final response = await httpClient.post(
    Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
    },
    body: jsonEncode({
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': buildTranslatePrompt(targetLang: config.targetLang, sourceLang: sourceLang, context: context)},
        {'role': 'user', 'content': text},
      ],
      'temperature': 0.3,
    }),
  );
  if (response.statusCode != 200) {
    throw HttpException('翻译接口返回 ${response.statusCode}: ${response.body}', uri: Uri.parse(config.baseUrl));
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final choices = body['choices'];
  if (choices is! List || choices.isEmpty) throw const HttpException('翻译接口未返回结果');
  final message = (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
  return message?['content'] as String? ?? '';
}

/// 翻译界面（划词翻译的独立面板）。
class TranslatePage extends ConsumerWidget {
  const TranslatePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(translateConfigProvider);
    final result = ref.watch(translateResultProvider);
    final translating = ref.watch(translatingProvider);
    final controller = TextEditingController();

    return Scaffold(
      appBar: AppBar(title: const Text('翻译')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '待翻译文本',
                border: OutlineInputBorder(),
                hintText: '在阅读器里选中文本，或直接粘贴到这里',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: config.targetLang,
                    decoration: const InputDecoration(labelText: '目标语言', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                      DropdownMenuItem(value: 'en', child: Text('英语')),
                      DropdownMenuItem(value: 'ja', child: Text('日语')),
                    ],
                    onChanged: (value) => ref.read(translateConfigProvider.notifier).state = TranslateConfig(
                          baseUrl: config.baseUrl,
                          model: config.model,
                          apiKey: config.apiKey,
                          targetLang: value ?? 'zh',
                        ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: translating
                      ? null
                      : () async {
                          ref.read(translatingProvider.notifier).state = true;
                          ref.read(translateResultProvider.notifier).state = null;
                          try {
                            final translated = await translateText(config: config, text: controller.text);
                            ref.read(translateResultProvider.notifier).state = translated;
                          } catch (error) {
                            ref.read(translateResultProvider.notifier).state = '翻译失败：$error';
                          } finally {
                            ref.read(translatingProvider.notifier).state = false;
                          }
                        },
                  icon: translating ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.translate),
                  label: const Text('翻译'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (result != null)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(child: SelectableText(result)),
                ),
              ),
            const Spacer(),
            Text(
              '接口：${config.baseUrl} · 模型：${config.model}\n'
              'Flutter 端直连翻译 API，不依赖 dsh（设计文档 3.6）',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
