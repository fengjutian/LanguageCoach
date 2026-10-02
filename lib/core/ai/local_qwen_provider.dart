import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/chat_models.dart';
import '../native/native_ai_bridge.dart';
import '../network/api_client.dart';
import 'llm_event.dart';
import 'llm_provider.dart';

/// Drives the on-device Qwen3 model through [NativeAiBridge]. Streaming
/// tokens come back as `LLM_TOKEN` events on the bridge's `eventStream`;
/// the provider concatenates them and wraps the final assembled text as a
/// [CoachResponse] at completion. P1-6 deliberately does not try to coerce
/// the raw model output into structured fields — that lands with the
/// post-P1-6 quality work. Until then, the chat UI renders the streamed
/// text verbatim and the rest of the [CoachResponse] slots stay empty.
class LocalQwenProvider implements LlmProvider {
  LocalQwenProvider({
    required NativeAiBridge bridge,
    required String modelId,
    Uuid? uuid,
  })  : _bridge = bridge,
        _modelId = modelId,
        _uuid = uuid ?? const Uuid();

  final NativeAiBridge _bridge;
  final String _modelId;
  final Uuid _uuid;

  @override
  String get id => 'Qwen3 (Local)';

  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) {
    final controller = StreamController<LlmEvent>();
    // Late-bound session id — we need it for cancellation, the buffer
    // snapshot at completion, and to filter bridge events to ours only.
    String? sessionId;
    final tokenBuffer = StringBuffer();
    var closed = false;

    Future<void> run() async {
      sessionId = _uuid.v4();
      String? started;
      try {
        started = await _bridge.startLlmGeneration(
          sessionId: sessionId!,
          prompt: _composePrompt(request, context),
          modelId: _modelId,
        );
      } catch (e) {
        if (!closed) {
          controller.add(LlmEventError(
            LlmError(LlmErrorKind.unknown, '本地模型启动失败: $e'),
          ));
          await controller.close();
          closed = true;
        }
        return;
      }
      if (started == null) {
        if (!closed) {
          controller.add(const LlmEventError(LlmError(
            LlmErrorKind.unknown,
            '本地模型未加载或启动被拒绝。',
          )));
          await controller.close();
          closed = true;
        }
        return;
      }

      late final StreamSubscription<LlmStreamEvent> sub;
      sub = _bridge.eventStream
          .map((frame) => frame.toLlmStreamEvent())
          .where((e) => e != null && e.sessionId == sessionId)
          .cast<LlmStreamEvent>()
          .listen((ev) async {
        if (closed) return;
        switch (ev.type) {
          case 'LLM_TOKEN':
            final token = (ev.payload['token'] as String?) ?? '';
            if (token.isEmpty) return;
            tokenBuffer.write(token);
            controller.add(LlmEventDelta(token));
            break;
          case 'LLM_COMPLETE':
            closed = true;
            final text = tokenBuffer.toString();
            controller.add(_buildComplete(text, request));
            await sub.cancel();
            await controller.close();
            break;
          case 'LLM_ERROR':
            closed = true;
            final message =
                (ev.payload['message'] as String?) ?? '本地模型推理失败';
            controller.add(LlmEventError(
              LlmError(LlmErrorKind.unknown, message),
            ));
            await sub.cancel();
            await controller.close();
            break;
        }
      }, onError: (Object e) async {
        if (closed) return;
        closed = true;
        controller.add(LlmEventError(
          LlmError(LlmErrorKind.unknown, '本地模型流错误: $e'),
        ));
        await controller.close();
      });

      // If the consumer cancels its subscription, forward that to the
      // runtime so we don't keep generating tokens.
      controller.onCancel = () async {
        if (closed) return;
        closed = true;
        if (sessionId != null) {
          await _bridge.cancelLlmGeneration(sessionId: sessionId!);
        }
        await sub.cancel();
      };
    }

    run();
    return controller.stream;
  }

  /// Compose the system + user prompt the local model sees. P1-6 keeps
  /// this intentionally minimal — the structured `CoachResponse` wrapping
  /// lives in [_buildComplete].
  String _composePrompt(CoachRequest request, List<ChatMessage> context) {
    final sys = StringBuffer()
      ..writeln('You are a friendly language practice partner.')
      ..writeln('Target language: ${request.targetLanguage.code}')
      ..writeln('Respond only in the target language, briefly.');
    final history = StringBuffer();
    for (final msg in context) {
      history.writeln('${msg.role.name}: ${msg.response?.primary ?? msg.response?.toString() ?? ''}');
    }
    if (history.isNotEmpty) {
      sys
        ..writeln()
        ..writeln('--- Conversation so far ---')
        ..writeln(history.toString())
        ..writeln('--- End of context ---');
    }
    sys
      ..writeln()
      ..writeln('User: ${request.text}');
    return sys.toString();
  }

  LlmEventComplete _buildComplete(String text, CoachRequest request) {
    final trimmed = text.trim();
    final response = CoachResponse(
      intent: request.intent,
      sourceLanguage: 'auto',
      targetLanguage: request.targetLanguage.code,
      primary: trimmed,
      alternatives: const <String>[],
      explanation: '由本地 Qwen3 模型生成。',
      sentences: trimmed.isEmpty
          ? const <CoachSentence>[]
          : [CoachSentence(id: 's1', text: trimmed)],
      keywords: const <String>[],
    );
    return LlmEventComplete(
      response,
      ChatMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: response,
        model: id,
      ),
    );
  }
}