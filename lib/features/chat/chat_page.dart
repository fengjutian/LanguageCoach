import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/llm_event.dart';
import '../../core/audio/asr_engine.dart';
import '../../core/database/app_database_provider.dart';
import '../../core/models/chat_models.dart';
import '../../core/native/native_ai_bridge.dart';
import '../../core/network/api_client.dart';
import '../../core/repositories/sqlite_conversation_repository.dart';
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
  final _uuid = const Uuid();
  StreamSubscription<Object?>? nativeEventSubscription;
  StreamSubscription<LlmEvent>? replySubscription;
  bool isStreaming = false;
  bool isListening = false;
  String _currentConversationId = '';
  String _lastUserInput = '';
  bool _hydrated = false;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(nativeAiBridgeProvider);
    nativeEventSubscription = bridge.eventStream.listen(
      _handleNativeEvent,
      onError: (Object error) => _showVoiceError(error.toString()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrate());
  }

  Future<void> _hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    final repo = ref.read(conversationRepositoryProvider);
    final settings = ref.read(settingsControllerProvider);
    if (settings.saveHistory &&
        settings.lastConversationId != null &&
        settings.lastConversationId!.isNotEmpty) {
      final id = settings.lastConversationId!;
      final msgs = await repo.messagesFor(id);
      if (!mounted) return;
      setState(() {
        _currentConversationId = id;
        messages
          ..clear()
          ..addAll(msgs);
      });
    } else {
      _currentConversationId = _uuid.v4();
    }
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
    if (!mounted) return;
    if (event is! Map) return;
    final result = event.toAsrResult();
    if (result == null) return;
    switch (result) {
      case AsrPartial(:final text):
        controller.text = text;
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);
        setState(() => isListening = true);
      case AsrFinal(:final text):
        controller.text = text;
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);
        setState(() => isListening = false);
      case AsrFailure(:final kind):
        setState(() => isListening = false);
        _showVoiceError(_describeAsrError(kind));
    }
  }

  String _describeAsrError(AsrErrorKind kind) {
    switch (kind) {
      case AsrErrorKind.permissionDenied:
        return '麦克风权限被拒绝';
      case AsrErrorKind.busy:
        return '识别器正忙，请稍后再试';
      case AsrErrorKind.modelMissing:
        return '语音模型未安装，请前往设置页下载';
      case AsrErrorKind.timeout:
        return '识别超时，请重试';
      case AsrErrorKind.unavailable:
        return '当前设备没有可用的语音识别服务';
      case AsrErrorKind.format:
        return '识别结果解析失败';
      case AsrErrorKind.unknown:
        return '语音识别失败';
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

    if (_currentConversationId.isEmpty) {
      _currentConversationId = _uuid.v4();
    }

    final settings = ref.read(settingsControllerProvider);
    final userMsg = ChatMessage(
      id: 'u_${_uuid.v4()}',
      role: MessageRole.user,
      sourceText: text,
      createdAt: DateTime.now(),
    );
    final placeholder = ChatMessage(
      id: 'a_${_uuid.v4()}',
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

    if (settings.saveHistory) {
      await _saveSettingsAndMessages(userMsg);
    }
    _beginReply(text, placeholder.id);
  }

  Future<void> _saveSettingsAndMessages(ChatMessage userMsg) async {
    final repo = ref.read(conversationRepositoryProvider);
    final settings = ref.read(settingsControllerProvider);
    await repo.ensureConversation(
      _currentConversationId,
      preferredLanguage: settings.preferredLanguage,
      targetLanguage: settings.preferredLanguage,
    );
    await repo.appendMessage(
      conversationId: _currentConversationId,
      message: userMsg,
    );
    if (settings.lastConversationId != _currentConversationId) {
      ref
          .read(settingsControllerProvider.notifier)
          .setLastConversationId(_currentConversationId);
    }
  }

  void _beginReply(String text, String placeholderId) {
    replySubscription?.cancel();
    final engine = ref.read(conversationEngineProvider);
    final settings = ref.read(settingsControllerProvider);
    final historyContext =
        settings.saveHistory ? _recentContext() : const <ChatMessage>[];
    replySubscription =
        engine.replyStream(text, context: historyContext).listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case LlmEventDelta(:final text):
            _appendDelta(placeholderId, text);
          case LlmEventComplete(:final response, :final assistantMessage):
            _finalizeMessage(placeholderId, assistantMessage);
            _persistAssistant(assistantMessage.copyWith(response: response));
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
        _scrollDown();
      },
    );
  }

  List<ChatMessage> _recentContext({int max = 20}) {
    if (messages.length <= max) return List.unmodifiable(messages);
    return List.unmodifiable(messages.sublist(messages.length - max));
  }

  Future<void> _persistAssistant(ChatMessage assistant) async {
    final settings = ref.read(settingsControllerProvider);
    if (!settings.saveHistory) return;
    final repo = ref.read(conversationRepositoryProvider);
    final id = _currentConversationId;
    if (id.isEmpty) return;
    await repo.ensureConversation(id);
    await repo.appendMessage(conversationId: id, message: assistant);

    // Auto-title from the first user input — cheap local heuristic.
    final repo0 = repo;
    if (repo0 is SqliteConversationRepository) {
      final meta = await repo0.findById(id);
      if (meta != null &&
          meta.title.startsWith('对话 ') &&
          _lastUserInput.isNotEmpty) {
        await repo0.updateTitle(id, _shortTitle(_lastUserInput));
      }
    }
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

  String _shortTitle(String sourceText) {
    final trimmed = sourceText.trim();
    if (trimmed.length <= 18) return trimmed;
    return '${trimmed.substring(0, 18)}…';
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
                    return MessageBubble(
                      message: message,
                      conversationId: _currentConversationId,
                    );
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

// kept for IDE reference; nothing else to anchor here.
