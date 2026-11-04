import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_state.dart';

/// 插件描述的机器翻译。
///
/// 走 DeepSeek 的 chat 接口，用用户自己的 API key；结果按「插件 + 语言」
/// 缓存在 SharedPreferences 里，同一个插件翻过一次就不再花钱。
class PluginTranslator {
  const PluginTranslator();

  static const model = 'deepseek-chat';
  static const _endpoint = 'https://api.deepseek.com/chat/completions';
  static const _prefPrefix = 'plugin_tr_';

  static String _cacheKey(String key, String lang) => '$_prefPrefix${lang}_$key';

  /// 读缓存；没有返回 null。
  Future<String?> cached(String key, String lang) async {
    final prefs = await SharedPreferences.getInstance();
    final hit = prefs.getString(_cacheKey(key, lang));
    return (hit == null || hit.isEmpty) ? null : hit;
  }

  Future<void> _save(String key, String lang, String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(key, lang), text);
  }

  /// 翻一段文本。失败返回 null（不抛）。
  Future<String?> translate({
    required String key,
    required String text,
    required String lang,
    required String apiKey,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final hit = await cached(key, lang);
    if (hit != null) return hit;
    final out = await _request(trimmed, lang, apiKey);
    if (out != null && out.isNotEmpty) await _save(key, lang, out);
    return out;
  }

  Future<String?> _request(String text, String lang, String apiKey) async {
    final target = switch (lang) {
      'en' => 'English',
      _ => 'Simplified Chinese',
    };
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 3);
    try {
      final req = await client.postUrl(Uri.parse(_endpoint));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..set(HttpHeaders.contentTypeHeader, 'application/json');
      req.write(jsonEncode({
        'model': model,
        'temperature': 0,
        'stream': false,
        'messages': [
          {
            'role': 'system',
            'content': 'You translate app/plugin descriptions. Translate into $target. '
                'Keep code, paths, URLs and product names unchanged. '
                'Output only the translation, no preamble.',
          },
          {'role': 'user', 'content': text},
        ],
      }));
      final res = await req.close().timeout(const Duration(seconds: 45));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final message = (choices.first as Map)['message'];
      if (message is! Map) return null;
      final content = message['content'];
      return content is String ? content.trim() : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

final pluginTranslatorProvider = Provider<PluginTranslator>((ref) => const PluginTranslator());

/// 一段可翻译的说明文字：默认显示原文，右上角一个「翻译」入口，
/// 点开后就地换成译文，并给出「原文 / 译文」切换。
class TranslatableDescription extends ConsumerStatefulWidget {
  const TranslatableDescription({
    super.key,
    required this.text,
    required this.cacheKey,
    this.style,
  });

  final String text;

  /// 缓存键，用「插件 id + 版本」之类稳定值。
  final String cacheKey;
  final TextStyle? style;

  @override
  ConsumerState<TranslatableDescription> createState() => _TranslatableDescriptionState();
}

class _TranslatableDescriptionState extends ConsumerState<TranslatableDescription> {
  String? _translated;
  bool _showingTranslation = false;
  bool _loading = false;
  bool _failed = false;

  String get _lang {
    final code = Localizations.localeOf(context).languageCode;
    return code == 'en' ? 'en' : 'zh';
  }

  Future<void> _toggle() async {
    if (_showingTranslation) {
      setState(() => _showingTranslation = false);
      return;
    }
    if (_translated != null) {
      setState(() => _showingTranslation = true);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    final apiKey = ref.read(settingsProvider).apiKey.trim();
    if (apiKey.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    final result = await ref.read(pluginTranslatorProvider).translate(
          key: widget.cacheKey,
          text: widget.text,
          lang: _lang,
          apiKey: apiKey,
        );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _translated = result;
      _showingTranslation = result != null;
      _failed = result == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = _showingTranslation && _translated != null ? _translated! : widget.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_showingTranslation)
              TextButton.icon(
                onPressed: _loading ? null : _toggle,
                icon: const Icon(Icons.undo, size: 16),
                label: const Text('原文'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              )
            else
              TextButton.icon(
                onPressed: _loading ? null : _toggle,
                icon: _loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.translate, size: 16),
                label: Text(_loading ? '翻译中' : (_failed ? '翻译失败，重试' : '翻译')),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            if (_showingTranslation) ...[
              const SizedBox(width: 4),
              Text('机器翻译', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ],
        ),
        SelectableText(body, style: widget.style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
      ],
    );
  }
}
