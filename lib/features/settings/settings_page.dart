import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/llm_event.dart';
import '../../core/ai/llm_provider.dart';
import '../../core/ai/minimax_provider.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/chat_models.dart';
import '../../core/network/api_client.dart';
import '../../core/security/secure_key_store.dart';
import '../chat/application/conversation_providers.dart';
import 'application/api_keys_controller.dart';
import 'application/settings_controller.dart';
import 'tts_benchmark_page.dart';

/// Speech-speed choices the audio pipeline will accept downstream. Kept in
/// sync with [AppSettings.allowedSpeechSpeeds] so the UI cannot suggest a
/// value the controller would later reject.
const _kSpeechSpeedStops = <double>[0.75, 0.85, 1.0, 1.15, 1.25, 1.5];

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('设置')),
        SliverList.list(
          children: [
            const _SectionTitle('语言'),
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('首选语言'),
              subtitle: const Text('对话中未明确指定时使用'),
              trailing: DropdownButton<CoachLanguage>(
                value: settings.preferredLanguage,
                underline: const SizedBox.shrink(),
                onChanged: (value) {
                  if (value != null) controller.setPreferredLanguage(value);
                },
                items: CoachLanguage.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text('${item.flag} ${item.label}'),
                      ),
                    )
                    .toList(),
              ),
            ),
            const _SectionTitle('AI'),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Provider'),
              subtitle: const Text('Auto 会根据任务复杂度自动选择'),
              trailing: DropdownButton<AiProvider>(
                value: settings.provider,
                underline: const SizedBox.shrink(),
                onChanged: (value) {
                  if (value != null) controller.setProvider(value);
                },
                items: AiProvider.values
                    .map(
                      (provider) => DropdownMenuItem(
                        value: provider,
                        child: Text(switch (provider) {
                          AiProvider.auto => 'Auto',
                          AiProvider.miniMax => 'MiniMax',
                          AiProvider.deepSeek => 'DeepSeek',
                          AiProvider.localQwen => 'Local Qwen3',
                        }),
                      ),
                    )
                    .toList(),
              ),
            ),
            const _ApiKeysSection(),
            const _SectionTitle('语音'),
            SwitchListTile(
              title: const Text('自动播放'),
              value: settings.autoPlay,
              onChanged: controller.setAutoPlay,
            ),
            ListTile(
              title: const Text('语速'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${settings.speechSpeed.toStringAsFixed(2)}x'),
                  Slider(
                    value: settings.speechSpeed,
                    min: _kSpeechSpeedStops.first,
                    max: _kSpeechSpeedStops.last,
                    divisions: _kSpeechSpeedStops.length - 1,
                    label: '${settings.speechSpeed.toStringAsFixed(2)}x',
                    onChanged: (next) {
                      final snapped = _kSpeechSpeedStops.reduce(
                        (a, b) => ((next - a).abs() < (next - b).abs()) ? a : b,
                      );
                      controller.setSpeechSpeed(snapped);
                    },
                  ),
                ],
              ),
            ),
            const _SectionTitle('会话'),
            SwitchListTile(
              title: const Text('保存聊天记录'),
              value: settings.saveHistory,
              onChanged: controller.setSaveHistory,
            ),
            const _SectionTitle('模型'),
            const ListTile(
              leading: Icon(Icons.memory),
              title: Text('Qwen3 0.6B'),
              subtitle: Text('尚未下载'),
              trailing: Icon(Icons.download_outlined),
            ),
            const ListTile(
              leading: Icon(Icons.graphic_eq),
              title: Text('Qwen3-TTS 0.6B'),
              subtitle: Text('尚未下载'),
              trailing: Icon(Icons.download_outlined),
            ),
            const ListTile(
              leading: Icon(Icons.hearing),
              title: Text('sherpa-onnx ASR'),
              subtitle: Text('尚未下载'),
              trailing: Icon(Icons.download_outlined),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('TTS Native Benchmark'),
              subtitle: const Text('调试：直接驱动 Qwen3-TTS 运行时'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _TtsBenchmarkEntry(),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ],
    );
  }
}

class _ApiKeysSection extends ConsumerWidget {
  const _ApiKeysSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maskedMiniMax = ref.watch(maskedKeyProvider(ApiKeySlot.miniMax));
    final maskedDeepSeek = ref.watch(maskedKeyProvider(ApiKeySlot.deepSeek));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('API Keys'),
        _KeyCard(
          label: 'MiniMax',
          endpoint: ref.watch(appConfigProvider).miniMax.baseUrl,
          maskedKey: maskedMiniMax,
          slot: ApiKeySlot.miniMax,
          tester: _testConnection(ApiKeySlot.miniMax, isMiniMax: true),
        ),
        _KeyCard(
          label: 'DeepSeek',
          endpoint: ref.watch(appConfigProvider).deepSeek.baseUrl,
          maskedKey: maskedDeepSeek,
          slot: ApiKeySlot.deepSeek,
          tester: _testConnection(ApiKeySlot.deepSeek, isMiniMax: false),
        ),
      ],
    );
  }

  _KeyTester _testConnection(ApiKeySlot slot, {required bool isMiniMax}) {
    return _KeyTester(slot: slot, isMiniMax: isMiniMax);
  }
}

class _KeyCard extends ConsumerStatefulWidget {
  const _KeyCard({
    required this.label,
    required this.endpoint,
    required this.maskedKey,
    required this.slot,
    required this.tester,
  });

  final String label;
  final String endpoint;
  final String? maskedKey;
  final ApiKeySlot slot;
  final _KeyTester tester;

  @override
  ConsumerState<_KeyCard> createState() => _KeyCardState();
}

class _KeyCardState extends ConsumerState<_KeyCard> {
  final _inputController = TextEditingController();
  bool _isEditing = false;
  bool _busy = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _inputController.text.trim();
    await ref
        .read(apiKeysControllerProvider.notifier)
        .write(widget.slot, value);
    if (!mounted) return;
    setState(() => _isEditing = false);
    _inputController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${widget.label} Key 已保存')),
    );
  }

  Future<void> _delete() async {
    await ref.read(apiKeysControllerProvider.notifier).delete(widget.slot);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${widget.label} Key 已删除')),
    );
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    final message = await widget.tester.run(ref);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = widget.maskedKey != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(widget.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
                const Spacer(),
                if (hasKey)
                  Chip(
                    label: Text(widget.maskedKey!),
                    visualDensity: VisualDensity.compact,
                  )
                else
                  const Chip(
                    label: Text('未配置'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(widget.endpoint,
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 12),
            if (_isEditing)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      obscureText: true,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText: '粘贴 ${widget.label} API Key',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: const Text('保存')),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => setState(() {
                      _isEditing = false;
                      _inputController.clear();
                    }),
                    child: const Text('取消'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _isEditing = true),
                    icon: Icon(hasKey ? Icons.edit : Icons.add),
                    label: Text(hasKey ? '替换' : '添加'),
                  ),
                  if (hasKey) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除'),
                    ),
                  ],
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: (hasKey && !_busy) ? _test : null,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    label: const Text('测试连接'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _KeyTester {
  const _KeyTester({required this.slot, required this.isMiniMax});
  final ApiKeySlot slot;
  final bool isMiniMax;

  Future<String> run(WidgetRef ref) async {
    final config = ref.read(appConfigProvider);
    final apiClient = ref.read(apiClientProvider);
    final keyStore = ref.read(secureKeyStoreProvider);
    final key = await keyStore.read(slot);
    if (key == null || key.isEmpty) {
      return 'Key 未配置';
    }

    final provider = isMiniMax
        ? MiniMaxProvider(
            endpoint: config.miniMax,
            apiClient: apiClient,
            apiKeyResolver: () async => key,
          )
        : DeepSeekProvider(
            endpoint: config.deepSeek,
            apiClient: apiClient,
            apiKeyResolver: () async => key,
          );

    final completer = await _drainFirst(provider);
    return completer;
  }

  Future<String> _drainFirst(LlmProvider provider) async {
    final request = const CoachRequest(
      text: 'ping',
      targetLanguage: CoachLanguage.english,
      intent: CoachIntent.conversation,
    );
    final events = <LlmEvent>[];
    await for (final event
        in provider.generateStream(request, const <ChatMessage>[])) {
      events.add(event);
      if (event is LlmEventComplete || event is LlmEventError) {
        break;
      }
    }
    if (events.isEmpty) return '测试无响应';
    final last = events.last;
    if (last is LlmEventError) {
      return switch (last.error.kind) {
        LlmErrorKind.unauthorized => '未授权：Key 无效',
        LlmErrorKind.rateLimited => '通过鉴权，但请求被限流',
        LlmErrorKind.timeout => '连接超时',
        LlmErrorKind.network => '网络不可达',
        LlmErrorKind.server => '上游服务异常',
        LlmErrorKind.format => '响应格式异常',
        LlmErrorKind.cancelled => '已取消',
        LlmErrorKind.unknown => '未知错误',
      };
    }
    return '连接成功（${provider.id}）';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

class _TtsBenchmarkEntry extends ConsumerWidget {
  const _TtsBenchmarkEntry();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _TtsBenchmarkRouter();
  }
}

class _TtsBenchmarkRouter extends StatelessWidget {
  const _TtsBenchmarkRouter();
  @override
  Widget build(BuildContext context) {
    return const TtsBenchmarkPage();
  }
}
