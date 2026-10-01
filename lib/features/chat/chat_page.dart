import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat_models.dart';
import '../settings/application/settings_controller.dart';
import 'application/conversation_providers.dart';
import 'widgets/message_bubble.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final controller = TextEditingController();
  final scrollController = ScrollController();
  final messages = <ChatMessage>[];
  StreamSubscription<Object?>? nativeEventSubscription;
  bool isLoading = false;
  bool isListening = false;

  @override
  void initState() {
    super.initState();
    // Subscribe to the bridge lazily so we capture the current instance on
    // first frame — Riverpod overrides in tests swap this provider without
    // touching widget state.
    final bridge = ref.read(nativeAiBridgeProvider);
    nativeEventSubscription = bridge.eventStream.listen(
      _handleNativeEvent,
      onError: (Object error) => _showVoiceError(error.toString()),
    );
  }

  @override
  void dispose() {
    nativeEventSubscription?.cancel();
    if (isListening) {
      // The listener may have been disposed already (tests) — best effort.
      unawaited(ref.read(nativeAiBridgeProvider).cancelListening());
    }
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<void> toggleListening() async {
    if (isListening) {
      await ref.read(nativeAiBridgeProvider).stopListening();
      return;
    }
    try {
      final available =
          await ref.read(nativeAiBridgeProvider).isSpeechRecognitionAvailable();
      if (!available) {
        _showVoiceError('当前设备没有可用的语音识别服务');
        return;
      }
      await ref.read(nativeAiBridgeProvider).startListening(
            language:
                ref.read(settingsControllerProvider).preferredLanguage.code,
          );
    } on PlatformException catch (error) {
      _showVoiceError(error.message ?? '无法启动语音识别');
    }
  }

  void _handleNativeEvent(Object? event) {
    if (!mounted || event is! Map) return;
    final type = event['type'];
    final payload = event['payload'];
    final data = payload is Map ? payload : const <Object?, Object?>{};
    switch (type) {
      case 'ASR_START':
      case 'ASR_READY':
      case 'ASR_SPEECH_START':
        setState(() => isListening = true);
      case 'ASR_PARTIAL':
        controller.text = data['text']?.toString() ?? '';
        controller.selection = TextSelection.collapsed(
          offset: controller.text.length,
        );
      case 'ASR_FINAL':
        controller.text = data['text']?.toString() ?? '';
        controller.selection = TextSelection.collapsed(
          offset: controller.text.length,
        );
        setState(() => isListening = false);
      case 'ASR_CANCELLED':
        setState(() => isListening = false);
      case 'ASR_ERROR':
        setState(() => isListening = false);
        _showVoiceError(data['message']?.toString() ?? '语音识别失败');
    }
  }

  void _showVoiceError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> send() async {
    final text = controller.text.trim();
    if (text.isEmpty || isLoading) return;
    controller.clear();
    setState(() {
      isLoading = true;
      messages.add(
        ChatMessage(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          role: MessageRole.user,
          sourceText: text,
          createdAt: DateTime.now(),
        ),
      );
    });
    _scrollDown();
    try {
      final engine = ref.read(conversationEngineProvider);
      final response = await engine.reply(text);
      if (mounted) setState(() => messages.add(response));
    } finally {
      if (mounted) setState(() => isLoading = false);
      _scrollDown();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _Header(),
        Expanded(
          child: messages.isEmpty
              ? const _EmptyState()
              : ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  itemCount: messages.length + (isLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      return const Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return MessageBubble(message: messages[index]);
                  },
                ),
        ),
        _Composer(
          controller: controller,
          onSend: send,
          onToggleListening: toggleListening,
          isListening: isListening,
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Language Coach',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                Text('自然地说，自信地学', style: TextStyle(color: Colors.black54)),
              ],
            ),
          ),
          Chip(
            label: Text(
              '${settings.preferredLanguage.flag} ${settings.preferredLanguage.label}',
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.record_voice_over_rounded, size: 42),
            ),
            const SizedBox(height: 22),
            const Text(
              '今天想练习什么？',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '试试：“今天下雨，怎么用英语表达？”',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onToggleListening,
    required this.isListening,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onToggleListening;
  final bool isListening;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Row(
          children: [
            IconButton(
              onPressed: onToggleListening,
              icon: Icon(isListening ? Icons.stop_circle : Icons.mic_none),
              color: isListening ? Theme.of(context).colorScheme.error : null,
              tooltip: isListening ? '停止识别' : '语音输入',
            ),
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: '输入你想学习的表达…',
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.arrow_upward_rounded),
              tooltip: '发送',
            ),
          ],
        ),
      ),
    );
  }
}
