import 'package:flutter/material.dart';

import '../../core/ai/conversation_engine.dart';
import '../../core/model/app_settings.dart';
import '../../core/model/chat_models.dart';
import 'widgets/message_bubble.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({required this.engine, required this.settings, super.key});
  final ConversationEngine engine;
  final AppSettings settings;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final controller = TextEditingController();
  final scrollController = ScrollController();
  final messages = <ChatMessage>[];
  bool isLoading = false;

  @override
  void dispose() {
    controller.dispose();
    scrollController.dispose();
    super.dispose();
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
      final response = await widget.engine.reply(text);
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
        _Header(settings: widget.settings),
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
                    return MessageBubble(
                      message: messages[index],
                      settings: widget.settings,
                    );
                  },
                ),
        ),
        _Composer(controller: controller, onSend: send),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Padding(
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
  const _Composer({required this.controller, required this.onSend});
  final TextEditingController controller;
  final VoidCallback onSend;

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
              onPressed: () {},
              icon: const Icon(Icons.mic_none),
              tooltip: '语音输入（Phase 2）',
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
