import 'dart:async';

import 'package:uuid/uuid.dart';

import '../audio/sentence_splitter.dart';
import '../models/chat_models.dart';
import '../native/native_ai_bridge.dart';
import '../network/api_client.dart';
import 'llm_event.dart';
import 'llm_provider.dart';

/// Drives the on-device Qwen3 model through [NativeAiBridge]. Streaming
/// tokens come back as `LLM_TOKEN` events on the bridge's `eventStream`;
/// the provider concatenates them and wraps the final assembled text as a
/// [CoachResponse] at completion.
///
/// P2-3 assembles a real [CoachResponse] instead of dumping raw text into
/// `primary`: the assembled text is split with [SentenceSplitter] so the
/// chat UI can render per-sentence play buttons, and a lightweight
/// frequency-based keyword extractor surfaces up to
/// [maxKeywords] vocabulary candidates for the vocabulary highlight
/// surface (P3+).
class LocalQwenProvider implements LlmProvider {
  LocalQwenProvider({
    required NativeAiBridge bridge,
    required String modelId,
    Uuid? uuid,
    SentenceSplitter? splitter,
    int maxKeywords = 4,
  })  : _bridge = bridge,
        _modelId = modelId,
        _uuid = uuid ?? const Uuid(),
        _splitter = splitter ?? const SentenceSplitter(),
        _maxKeywords = maxKeywords;

  final NativeAiBridge _bridge;
  final String _modelId;
  final Uuid _uuid;
  final SentenceSplitter _splitter;
  final int _maxKeywords;

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
    final rawSentences = _splitter.split(trimmed);
    final sentences = <CoachSentence>[];
    for (var i = 0; i < rawSentences.length; i++) {
      sentences.add(CoachSentence(id: 's${i + 1}', text: rawSentences[i]));
    }
    final keywords = _extractKeywords(trimmed, max: _maxKeywords);

    final response = CoachResponse(
      intent: request.intent,
      sourceLanguage: 'auto',
      targetLanguage: request.targetLanguage.code,
      primary: trimmed,
      alternatives: const <String>[],
      explanation: '由本地 Qwen3 模型生成。',
      sentences: sentences,
      keywords: keywords,
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

  /// Cheap frequency-based keyword extractor. P2-3 doesn't try to be
  /// clever — it's just enough for the chat UI to render a "vocab"
  /// pill row. Languages with non-space word boundaries (Chinese,
  /// Japanese) end up with character-level granularity; that's fine
  /// for P2-3 and gets swapped for a proper tokenizer in P3+.
  List<String> _extractKeywords(String text, {required int max}) {
    if (text.isEmpty) return const <String>[];
    final stopwords = _stopwordsFor(_langHint(text));
    final tokens = _tokenize(text, stopwords);
    if (tokens.isEmpty) return const <String>[];

    final counts = <String, int>{};
    for (final token in tokens) {
      counts[token] = (counts[token] ?? 0) + 1;
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    return ranked
        .take(max)
        .map((e) => e.key)
        .toList(growable: false);
  }

  String _langHint(String text) {
    // Heuristic: if the text contains CJK characters, treat it as
    // CJK for stopword selection. Otherwise default to latin.
    for (final rune in text.runes) {
      if (rune >= 0x4e00 && rune <= 0x9fff) return 'cjk';
    }
    return 'latin';
  }

  List<String> _tokenize(String text, Set<String> stopwords) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    void flush() {
      final token = buffer.toString().toLowerCase();
      buffer.clear();
      if (token.isEmpty) return;
      if (stopwords.contains(token)) return;
      if (token.length < 2) return;
      tokens.add(token);
    }

    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final isWord = RegExp(r'\w').hasMatch(ch);
      if (isWord) {
        buffer.write(ch);
      } else {
        flush();
      }
    }
    flush();
    return tokens;
  }

  Set<String> _stopwordsFor(String lang) {
    if (lang == 'cjk') {
      // CJK is character-based; we use a small list of common particles
      // + generic connectives as stopwords. The tokeniser treats every
      // CJK character as a token, so this matters more than for latin.
      return const <String>{
        '的', '了', '是', '在', '我', '你', '他', '她', '它',
        '和', '与', '或', '也', '都', '就', '还', '要', '把',
        '不', '没', '有', '对', '这', '那', '一个', '一些',
      };
    }
    return const <String>{
      'the', 'a', 'an', 'and', 'or', 'but', 'if', 'then',
      'is', 'are', 'was', 'were', 'be', 'been', 'being',
      'i', 'you', 'he', 'she', 'it', 'we', 'they',
      'to', 'of', 'in', 'on', 'at', 'for', 'with', 'by',
      'this', 'that', 'these', 'those',
    };
  }
}