import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/llm_event.dart';
import '../../core/models/chat_models.dart';
import '../../core/network/api_client.dart';
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
  StreamSubscription<LlmEvent>? replySubscription;
  bool isStreaming = false;
  bool isListening = false;

  /// Last user input — kept so the stop / retry button can replay it.
  String _lastUserInput = '';

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(nativeAiBridgeProvider);
    nativeEventSubscription = bridge.eventStream.listen(
      _handleNativeEvent,
      onError: (Object error) => _showVoiceError(error.toString()),
    );
  }

  @override
  void dispose() {
    nativeEventSubscription?.cancel();
    replySubscription?.cancel();
    if (isListening) {
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
    if (isStreaming) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;
    controller.clear();
    _lastUserInput = text;
    final userMsg = ChatMessage(
      id: 'u_${DateTime.now().microsecondsSinceEpoch}',
      role: MessageRole.user,
      sourceText: text,
      createdAt: DateTime.now(),
    );
    final placeholder = ChatMessage(
      id: 'a_${DateTime.now().microsecondsSinceEpoch}',
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
    );
    setState(() {
      messages
        ..add(userMsg)
        ..add(placeholder);
      isStreaming = true;
    });
    _scrollDown();
    _beginReply(text, placeholder.id);
  }

  void _beginReply(String text, String placeholderId) {
    replySubscription?.cancel();
    final engine = ref.read(conversationEngineProvider);
    final completer = Completer<void>();
    replySubscription = engine.replyStream(text).listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case LlmEventDelta(:final text):
            _appendDelta(placeholderId, text);
          case LlmEventComplete(:final response, :final assistantMessage):
            _finalizeMessage(
                placeholderId,
                assistantMessage.copyWith(
                  response: response,
                ));
          case LlmEventError(:final error):
            _renderError(placeholderId, error);
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        _renderError(
            placeholderId, LlmError(LlmErrorKind.unknown, e.toString()));
      },
      onDone: () {
        if (!mounted) return;
        setState(() => isStreaming = false);
        if (!completer.isCompleted) completer.complete();
        _scrollDown();
      },
    );
  }

  void _appendDelta(String id, String delta) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final current = messages[idx];
    final response = current.response ??
        CoachResponse(
          intent: CoachIntent.conversation,
          sourceLanguage: 'auto',
          targetLanguage: '',
          primary: '',
          explanation: '',
          sentences: const <CoachSentence>[],
        );
    final next = response.copyWith(primary: response.primary + delta);
    setState(() {
      messages[idx] = current.copyWith(response: next);
    });
  }

  void _finalizeMessage(String id, ChatMessage finalized) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    setState(() {
      messages[idx] = finalized.copyWith(id: id);
    });
  }

  void _renderError(String id, LlmError error) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    setState(() {
      messages[idx] = ChatMessage(
        id: id,
        role: MessageRole.error,
        createdAt: DateTime.now(),
        sourceText: _describe(error),
      );
    });
  }

  void stopReply() {
    replySubscription?.cancel();
    replySubscription = null;
    if (!mounted) return;
    // Keep the trailing placeholder as a partial answer; the composer swaps
    // back to the send button now that isStreaming is false.
    setState(() => isStreaming = false);
    _scrollDown();
  }

  void retryLast() {
    if (_lastUserInput.isEmpty || isStreaming) return;
    controller.text = _lastUserInput;
    send();
  }

  String _describe(LlmError error) {
    return switch (error.kind) {
      LlmErrorKind.unauthorized => '未授权：请检查 API Key',
      LlmErrorKind.rateLimited => '请求过于频繁，请稍后再试',
      LlmErrorKind.timeout => '请求超时，请检查网络',
      LlmErrorKind.network => '网络不可用',
      LlmErrorKind.format => '模型返回格式异常',
      LlmErrorKind.server => '上游服务异常',
      LlmErrorKind.cancelled => '已取消',
      LlmErrorKind.unknown => '未知错误',
    };
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
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    if (message.role == MessageRole.error) {
                      return _ErrorBubble(
                        text: message.sourceText ?? '',
                        onRetry: _lastUserInput.isEmpty ? null : retryLast,
                      );
                    }
                    return MessageBubble(message: message);
                  },
                ),
        ),
        _Composer(
          controller: controller,
          onSend: send,
          onToggleListening: toggleListening,
          onStop: isStreaming ? stopReply : null,
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
    required this.onStop,
    required this.isListening,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onToggleListening;
  final VoidCallback? onStop;
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
            if (onStop != null)
              IconButton(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: '停止生成',
              )
            else
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

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.text, this.onRetry});
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer))),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
