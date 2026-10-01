import 'package:flutter/material.dart';

import '../../../core/model/app_settings.dart';
import '../../../core/model/chat_models.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    required this.settings,
    super.key,
  });
  final ChatMessage message;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    if (message.role == MessageRole.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          constraints: const BoxConstraints(maxWidth: 330),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            message.sourceText ?? '',
            style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
          ),
        ),
      );
    }
    final response = message.response!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CircleAvatar(
                radius: 14,
                child: Icon(Icons.auto_awesome, size: 15),
              ),
              const SizedBox(width: 8),
              Text(
                message.model ?? 'AI Coach',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            response.primary,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          if (response.alternatives.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              response.alternatives.first,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            children: [
              IconButton.filledTonal(
                onPressed: () {},
                icon: const Icon(Icons.volume_up_outlined),
                tooltip: '播放（Phase 3）',
              ),
              ...[0.75, 1.0, 1.25, 1.5].map(
                (speed) => ChoiceChip(
                  label: Text('${speed}x'),
                  selected: settings.speechSpeed == speed,
                  onSelected: (_) => settings.setSpeechSpeed(speed),
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          const Text('解释', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(response.explanation),
          const SizedBox(height: 14),
          ...response.sentences.map(
            (sentence) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.play_circle_outline),
              title: Text(sentence.text),
              subtitle: const Text('逐句播放将在 TTS 接入后启用'),
            ),
          ),
        ],
      ),
    );
  }
}
