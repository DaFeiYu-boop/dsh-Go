import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_state.dart';

/// 一次翻译的结果：成功带译文，失败带能看懂的原因。
class TranslationOutcome {
  const TranslationOutcome.ok(String this.text) : error = null;
  const TranslationOutcome.fail(String this.error) : text = null;

  final String? text;
  final String? error;

  bool get isOk => text != null;
}

/// 插件描述的机器翻译。
///
/// 走 DeepSeek 的 chat 接口，用用户自己的 API key；结果按「插件 + 语言」
/// 缓存在 SharedPreferences 里，同一个插件翻过一次就不再花钱。
///
/// 模型按 [_models] 顺序试：老名字失效时自动落到新名字上。
class PluginTranslator {
  const PluginTranslator();

  static const _models = ['deepseek-chat', 'deepseek-flash'];
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

  /// 翻一段文本。失败不抛，返回带原因的结果。
  Future<TranslationOutcome> translate({
    required String key,
    required String text,
    required String lang,
    required String apiKey,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const TranslationOutcome.fail('这段说明是空的');
    final hit = await cached(key, lang);
    if (hit != null) return TranslationOutcome.ok(hit);

    TranslationOutcome last = const TranslationOutcome.fail('没有可用的模型');
    for (final model in _models) {
      final out = await _request(trimmed, lang, apiKey, model);
      if (out.isOk) {
        await _save(key, lang, out.text!);
        return out;
      }
      last = out;
      // key 不对就别再换个模型重试了。
      final err = out.error ?? '';
      if (err.contains('401') || err.contains('403')) break;
    }
    return last;
  }

  Future<TranslationOutcome> _request(
    String text,
    String lang,
    String apiKey,
    String model,
  ) async {
    final target = switch (lang) {
      'en' => 'English',
      _ => 'Simplified Chinese',
    };
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 3);
    try {
      final req = await client.postUrl(Uri.parse(_endpoint));
      // 自己编码成 UTF-8 字节再 add()：不碰 IOSink.encoding。
      // 先设 headers 再改 encoding 会抛 Bad state: IOSink encoding is not mutable。
      final payload = utf8.encode(jsonEncode({
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
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
        ..set(HttpHeaders.contentLengthHeader, '${payload.length}');
      req.add(payload);
      final res = await req.close().timeout(const Duration(seconds: 50));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 50));
      if (res.statusCode != 200) {
        final snippet = body.length > 240 ? '${body.substring(0, 240)}…' : body;
        return TranslationOutcome.fail('HTTP ${res.statusCode}（$model）：$snippet');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const TranslationOutcome.fail('接口返回的不是 JSON 对象');
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        return const TranslationOutcome.fail('接口没有返回 choices');
      }
      final message = (choices.first as Map)['message'];
      if (message is! Map) {
        return const TranslationOutcome.fail('接口没有返回 message');
      }
      final content = message['content'];
      if (content is! String || content.trim().isEmpty) {
        return const TranslationOutcome.fail('接口返回了空译文');
      }
      return TranslationOutcome.ok(content.trim());
    } on SocketException catch (e) {
      return TranslationOutcome.fail('连不上 api.deepseek.com（${e.osError?.message ?? e.message}）');
    } on TimeoutException {
      return const TranslationOutcome.fail('请求超时（api.deepseek.com 没在 50 秒内回）');
    } on HandshakeException catch (e) {
      return TranslationOutcome.fail('TLS 握手失败（${e.message}）');
    } catch (e) {
      return TranslationOutcome.fail('$e');
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
  String? _error;
  bool _showingTranslation = false;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // 翻过就记住：这次进来如果缓存里已经有译文，直接显示译文。
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  Future<void> _restore() async {
    if (!mounted) return;
    final hit = await ref.read(pluginTranslatorProvider).cached(widget.cacheKey, _lang);
    if (!mounted || hit == null || hit.isEmpty) return;
    setState(() {
      _translated = hit;
      _showingTranslation = true;
    });
  }

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
      _error = null;
    });
    final apiKey = ref.read(settingsProvider).apiKey.trim();
    if (apiKey.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _error = '没有找到 API key（设置 → 模型 里配一下）';
      });
      return;
    }
    final out = await ref.read(pluginTranslatorProvider).translate(
          key: widget.cacheKey,
          text: widget.text,
          lang: _lang,
          apiKey: apiKey,
        );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _translated = out.text;
      _error = out.error;
      _showingTranslation = out.isOk;
      _failed = !out.isOk;
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
              Text('机器翻译',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ],
        ),
        if (_failed && _error != null) ...[
          const SizedBox(height: 2),
          SelectableText(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        SelectableText(body,
            style: widget.style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
      ],
    );
  }
}
