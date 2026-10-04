import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/llm_event.dart';
import '../../core/models/chat_models.dart';
import '../chat/application/conversation_providers.dart';
import '../chat/application/speech_session_controller.dart';

class RoleplayScenario {
  const RoleplayScenario({
    required this.title,
    required this.userRole,
    required this.aiRole,
    required this.goal,
    required this.opening,
    required this.icon,
  });

  final String title;
  final String userRole;
  final String aiRole;
  final String goal;
  final String opening;
  final IconData icon;
}

const roleplayScenarios = <RoleplayScenario>[
  RoleplayScenario(
    title: '酒店入住',
    userRole: '住客',
    aiRole: '前台接待员',
    goal: '完成入住，确认早餐时间和退房时间',
    opening: 'Good evening. Welcome to the hotel. How may I help you?',
    icon: Icons.hotel_outlined,
  ),
  RoleplayScenario(
    title: '餐厅点餐',
    userRole: '顾客',
    aiRole: '服务员',
    goal: '完成点餐，询问推荐并说明饮食要求',
    opening:
        'Hello! Are you ready to order, or would you like a recommendation?',
    icon: Icons.restaurant_outlined,
  ),
  RoleplayScenario(
    title: '求职面试',
    userRole: '应聘者',
    aiRole: '面试官',
    goal: '完成自我介绍并回答经历、优势和求职动机',
    opening:
        'Thanks for coming in today. Could you start by introducing yourself?',
    icon: Icons.work_outline,
  ),
];

class RoleplayPage extends ConsumerStatefulWidget {
  const RoleplayPage({super.key});

  @override
  ConsumerState<RoleplayPage> createState() => _RoleplayPageState();
}

class _RoleplayPageState extends ConsumerState<RoleplayPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _uuid = const Uuid();
  final _messages = <ChatMessage>[];
  StreamSubscription<LlmEvent>? _subscription;

  int _selectedScenario = 0;
  bool _started = false;
  bool _waiting = false;
  bool _summarizing = false;
  String? _summary;
  String _streamingText = '';

  RoleplayScenario get _scenario => roleplayScenarios[_selectedScenario];

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(speechSessionControllerProvider, (previous, next) {
      if (next.partialText.isNotEmpty) {
        _input.text = next.partialText;
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roleplay'),
        actions: [
          if (_started && _summary == null)
            TextButton(
              onPressed: _waiting || _summarizing ? null : _finish,
              child: const Text('结束并总结'),
            ),
        ],
      ),
      body: _started ? _buildSession(context) : _buildSetup(context),
    );
  }

  Widget _buildSetup(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('选择练习场景',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('明确角色与目标后，教练会始终保持角色，直到你主动结束。'),
        const SizedBox(height: 20),
        ...roleplayScenarios.asMap().entries.map((entry) {
          final selected = entry.key == _selectedScenario;
          final scenario = entry.value;
          return Card(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: ListTile(
              leading: Icon(scenario.icon),
              title: Text(scenario.title),
              subtitle: Text('${scenario.userRole} ↔ ${scenario.aiRole}'),
              trailing: selected ? const Icon(Icons.check_circle) : null,
              onTap: () => setState(() => _selectedScenario = entry.key),
            ),
          );
        }),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本次目标', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(_scenario.goal),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.theater_comedy_outlined),
          label: const Text('进入场景'),
        ),
      ],
    );
  }

  Widget _buildSession(BuildContext context) {
    if (_summary != null) return _buildSummary(context);
    if (_summarizing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在生成本次练习总结…'),
          ],
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.secondaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            '${_scenario.title} · 你是${_scenario.userRole} · 目标：${_scenario.goal}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length + (_streamingText.isEmpty ? 0 : 1),
            itemBuilder: (context, index) {
              if (index == _messages.length) {
                return _RoleBubble(text: _streamingText, fromUser: false);
              }
              final message = _messages[index];
              return _RoleBubble(
                text: message.role == MessageRole.user
                    ? message.sourceText ?? ''
                    : message.response?.primary ?? '',
                fromUser: message.role == MessageRole.user,
              );
            },
          ),
        ),
        if (_waiting) const LinearProgressIndicator(),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: '语音输入',
                  onPressed: _waiting ? null : _toggleListening,
                  icon: Icon(
                      ref.watch(speechSessionControllerProvider).listening
                          ? Icons.stop_circle_outlined
                          : Icons.mic_none_rounded),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: !_waiting,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '以${_scenario.userRole}身份回应…',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton.filled(
                  onPressed: _waiting ? null : _send,
                  icon: const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context) {
    final userTurns = _messages.where((m) => m.role == MessageRole.user).length;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.emoji_events_outlined,
            size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text('场景练习完成',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text('${_scenario.title} · $userTurns 轮对话',
            textAlign: TextAlign.center),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('教练总结',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Text(_summary!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton(
          onPressed: _restart,
          child: const Text('再练一次'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }

  void _start() {
    final response = CoachResponse(
      intent: CoachIntent.roleplay,
      sourceLanguage: 'auto',
      targetLanguage: 'auto',
      primary: _scenario.opening,
      explanation: '',
      sentences: [CoachSentence(id: 'opening', text: _scenario.opening)],
    );
    setState(() {
      _started = true;
      _messages.add(ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: response,
        model: 'scenario',
      ));
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _waiting) return;
    _input.clear();
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      createdAt: DateTime.now(),
      sourceText: text,
    );
    setState(() {
      _messages.add(userMessage);
      _waiting = true;
      _streamingText = '';
    });
    _scrollDown();

    final prompt = '''角色扮演场景：${_scenario.title}
你是${_scenario.aiRole}，用户是${_scenario.userRole}。
用户目标：${_scenario.goal}
请始终保持角色，只回复角色台词；使用当前目标语言；回复简短自然，并通过追问推进场景。
用户刚才说：$text''';
    await _subscription?.cancel();
    _subscription = ref
        .read(conversationEngineProvider)
        .replyStream(prompt, context: List.unmodifiable(_messages))
        .listen(_onEvent,
            onError: (_) => _completeWithFallback(),
            onDone: () {
              if (mounted && _waiting) setState(() => _waiting = false);
            });
  }

  void _onEvent(LlmEvent event) {
    if (!mounted) return;
    switch (event) {
      case LlmEventDelta(:final text):
        setState(() => _streamingText += text);
      case LlmEventThinking():
        break;
      case LlmEventComplete(:final assistantMessage):
        setState(() {
          _messages.add(assistantMessage);
          _streamingText = '';
          _waiting = false;
        });
        _scrollDown();
      case LlmEventError():
        _completeWithFallback();
    }
  }

  void _completeWithFallback() {
    if (!mounted || !_waiting) return;
    final fallback = CoachResponse(
      intent: CoachIntent.roleplay,
      sourceLanguage: 'auto',
      targetLanguage: 'auto',
      primary: 'I understand. Could you tell me a little more?',
      explanation: '',
      sentences: const [
        CoachSentence(
            id: 'fallback',
            text: 'I understand. Could you tell me a little more?'),
      ],
    );
    setState(() {
      _messages.add(ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: fallback,
        model: 'fallback',
      ));
      _streamingText = '';
      _waiting = false;
    });
  }

  Future<void> _toggleListening() async {
    final controller = ref.read(speechSessionControllerProvider.notifier);
    final state = ref.read(speechSessionControllerProvider);
    try {
      if (state.listening) {
        await controller.stop();
      } else {
        await controller.start();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('语音输入失败：$error')));
      }
    }
  }

  Future<void> _finish() async {
    await _subscription?.cancel();
    setState(() {
      _waiting = false;
      _summarizing = true;
      _streamingText = '';
    });
    final transcript = _messages.map((m) {
      final speaker =
          m.role == MessageRole.user ? _scenario.userRole : _scenario.aiRole;
      final text = m.sourceText ?? m.response?.primary ?? '';
      return '$speaker: $text';
    }).join('\n');
    final prompt = '''请结束这次角色扮演训练并用中文给出简短总结。
场景：${_scenario.title}
目标：${_scenario.goal}
对话：
$transcript
请包含：目标完成情况、两点做得好的地方、两个可改进表达。''';
    var generated = '';
    try {
      await for (final event
          in ref.read(conversationEngineProvider).replyStream(prompt)) {
        switch (event) {
          case LlmEventDelta(:final text):
            generated += text;
          case LlmEventComplete(:final response):
            generated =
                response.primary.isNotEmpty ? response.primary : generated;
          case LlmEventThinking() || LlmEventError():
            break;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    final turns = _messages.where((m) => m.role == MessageRole.user).length;
    setState(() {
      _summarizing = false;
      _summary = generated.trim().isNotEmpty
          ? generated.trim()
          : '你完成了 $turns 轮对话。能够主动推进“${_scenario.goal}”这一目标。建议下一次使用更完整的句子，并在关键请求后补充礼貌表达。';
    });
  }

  void _restart() {
    setState(() {
      _messages.clear();
      _summary = null;
      _started = false;
      _waiting = false;
      _summarizing = false;
    });
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    });
  }
}

class _RoleBubble extends StatelessWidget {
  const _RoleBubble({required this.text, required this.fromUser});
  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) => Align(
        alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: fromUser
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(text),
        ),
      );
}
