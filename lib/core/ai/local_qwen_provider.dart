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
    Duration idleTimeout = const Duration(seconds: 90),
  })  : _bridge = bridge,
        _modelId = modelId,
        _uuid = uuid ?? const Uuid(),
        _splitter = splitter ?? const SentenceSplitter(),
        _maxKeywords = maxKeywords,
        _idleTimeout = idleTimeout;

  final NativeAiBridge _bridge;
  final String _modelId;
  final Uuid _uuid;
  final SentenceSplitter _splitter;
  final int _maxKeywords;

  /// How long the bridge may stay silent before we give up on the turn.
  /// Reset on every token so long generations are not cut short.
  final Duration _idleTimeout;

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
      // The bridge is a broadcast EventChannel: it completes when Android
      // tears it down, and a wedged runtime never sends LLM_COMPLETE /
      // LLM_ERROR at all. Without an `onDone` + idle watchdog the chat
      // bubble would spin forever with the stop button dead.
      Timer? watchdog;

      void stopWatchdog() {
        watchdog?.cancel();
        watchdog = null;
      }

      void armWatchdog() {
        stopWatchdog();
        watchdog = Timer(_idleTimeout, () {
          if (closed) return;
          closed = true;
          stopWatchdog();
          controller.add(LlmEventError(LlmError(
            LlmErrorKind.timeout,
            '本地模型 ${_idleTimeout.inSeconds} 秒没有输出，已中止本次生成。',
          )));
          unawaited(sub.cancel());
          unawaited(controller.close());
        });
      }

      sub = _bridge.eventStream
          .map((frame) => frame.toLlmStreamEvent())
          .where((e) => e != null && e.sessionId == sessionId)
          .cast<LlmStreamEvent>()
          .listen((ev) async {
        if (closed) return;
        armWatchdog();
        switch (ev.type) {
          case 'LLM_TOKEN':
            final token = ev.payload['token'];
            if (token is! String || token.isEmpty) return;
            tokenBuffer.write(token);
            controller.add(LlmEventDelta(token));
            break;
          case 'LLM_COMPLETE':
            closed = true;
            stopWatchdog();
            final text = tokenBuffer.toString();
            controller.add(_buildComplete(text, request));
            await sub.cancel();
            await controller.close();
            break;
          case 'LLM_ERROR':
            closed = true;
            stopWatchdog();
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
        stopWatchdog();
        controller.add(LlmEventError(
          LlmError(LlmErrorKind.unknown, '本地模型流错误: $e'),
        ));
        await controller.close();
      }, onDone: () {
        // Stream ended without LLM_COMPLETE / LLM_ERROR (activity destroy,
        // model unloaded, bridge torn down). Flush what we already got so
        // the turn terminates instead of hanging on a permanent spinner.
        if (closed) return;
        closed = true;
        stopWatchdog();
        final text = tokenBuffer.toString();
        if (text.trim().isEmpty) {
          controller.add(const LlmEventError(LlmError(
            LlmErrorKind.timeout,
            '本地模型生成被中断，没有收到任何内容。',
          )));
        } else {
          controller.add(_buildComplete(text, request));
        }
        unawaited(controller.close());
      });

      armWatchdog();

      // If the consumer cancels its subscription, forward that to the
      // runtime so we don't keep generating tokens.
      controller.onCancel = () async {
        stopWatchdog();
        if (closed) return;
        closed = true;
        if (sessionId != null) {
          await _bridge.cancelLlmGeneration(sessionId: sessionId!);
        }
        await sub.cancel();
      };
    }

    unawaited(run().catchError((Object e) {
      if (closed) return Future<void>.value();
      closed = true;
      controller.add(LlmEventError(
        LlmError(LlmErrorKind.unknown, '本地模型推理异常: $e'),
      ));
      return controller.close();
    }));
    return controller.stream;
  }

  /// Compose the system + user prompt the local model sees. P1-6 keeps
  /// this intentionally minimal — the structured `CoachResponse` wrapping
  /// lives in [_buildComplete].
  String _composePrompt(CoachRequest request, List<ChatMessage> context) {
    final sys = StringBuffer()
      ..writeln('You are a friendly language tutor.')
      ..writeln('Target language: ${request.targetLanguage.code}')
      ..writeln('Always teach the user, even when their input is only one word, name, or place.')
      ..writeln('Return exactly two sections in this format:')
      ..writeln('<ANSWER>')
      ..writeln('A brief, natural answer in the target language.')
      ..writeln('<EXPLANATION>')
      ..writeln('A useful explanation in the user\'s language. For a word or place, include its meaning, pronunciation or transliteration, and a usage note.')
      ..writeln('Never leave either section empty.');
    final history = StringBuffer();
    for (final msg in context) {
      // User turns keep their text in `sourceText` and have a null
      // `response`, so reading only `response` emitted an empty `user:` line
      // for every prior turn — the model never saw what the user said.
      final text = msg.role == MessageRole.user
          ? (msg.sourceText ?? '')
          : (msg.response?.primary ?? msg.response?.toString() ?? '');
      if (text.trim().isEmpty) continue;
      history.writeln('${msg.role.name}: ${text.trim()}');
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
    final extraction = _extractThinking(trimmed);
    final cleaned = extraction.cleaned.isEmpty ? trimmed : extraction.cleaned;
    final sections = _splitTeachingSections(cleaned);
    final answer = sections.answer;
    final rawSentences = _splitter.split(answer);
    final sentences = <CoachSentence>[];
    for (var i = 0; i < rawSentences.length; i++) {
      sentences.add(CoachSentence(id: 's${i + 1}', text: rawSentences[i]));
    }
    final keywords = _extractKeywords(answer, max: _maxKeywords);

    final response = CoachResponse(
      intent: request.intent,
      sourceLanguage: 'auto',
      targetLanguage: request.targetLanguage.code,
      primary: answer,
      thinking: extraction.thinking,
      alternatives: const <String>[],
      explanation: sections.explanation,
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

  _TeachingSections _splitTeachingSections(String text) {
    const answerMarker = '<ANSWER>';
    const explanationMarker = '<EXPLANATION>';
    final explanationAt = text.indexOf(explanationMarker);
    if (explanationAt < 0) {
      return _TeachingSections(
        text.replaceFirst(answerMarker, '').trim(),
        '本地模型没有返回教学解释。你可以点击重新生成，或直接追问“请解释这个表达”。',
      );
    }
    final answer = text
        .substring(0, explanationAt)
        .replaceFirst(answerMarker, '')
        .trim();
    final explanation = text
        .substring(explanationAt + explanationMarker.length)
        .trim();
    return _TeachingSections(
      answer.isEmpty ? text.trim() : answer,
      explanation.isEmpty
          ? '本地模型没有返回教学解释。你可以点击重新生成，或直接追问“请解释这个表达”。'
          : explanation,
    );
  }

  /// Mirrors [StructuredResponseParser._splitThinking] so the on-device Qwen
  /// output is cleaned up the same way the cloud providers' content is.
  /// The local bridge doesn't currently emit a separate reasoning channel,
  /// but if it ever does (or if the prompt starts wrapping output in tags),
  /// this is the seam.
  _ThinkingSplit _extractThinking(String input) {
    if (input.isEmpty) return const _ThinkingSplit('', '');
    final parts = <String>[];
    for (final m in _thinkingBlock.allMatches(input)) {
      for (var i = 1; i <= m.groupCount; i++) {
        final inner = m.group(i);
        if (inner != null) {
          final t = inner.trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
    }
    if (parts.isEmpty) return _ThinkingSplit('', input);
    final cleaned = input.replaceAll(_thinkingBlock, '').trim();
    return _ThinkingSplit(parts.join('\n\n'), cleaned);
  }

  static final RegExp _thinkingBlock = RegExp(
    r'<think>([\s\S]*?)<\/think>'
    r'|<reasoning>([\s\S]*?)<\/reasoning>'
    r'|<\|begin_of_thinking\|>([\s\S]*?)<\|end_of_thinking\|>'
    r'|【思考】([\s\S]*?)【\/思考】',
    caseSensitive: false,
  );

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
    // Heuristic: if the text contains CJK characters (kanji, kana or
    // hangul), treat it as CJK for stopword selection. Otherwise latin.
    if (_cjkChar.hasMatch(text)) return 'cjk';
    return 'latin';
  }

  List<String> _tokenize(String text, Set<String> stopwords) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    // CJK has no word boundaries and Dart's `\w` is ASCII-only, so every
    // Chinese/Japanese character used to be flushed on its own and then
    // dropped by the `length < 2` filter — keywords were always empty for
    // CJK output. Latin runs still need the ASCII class.
    final isCjk = _cjkChar.hasMatch(text);
    void flush({required bool cjk}) {
      final token = buffer.toString().toLowerCase();
      buffer.clear();
      if (token.isEmpty) return;
      if (stopwords.contains(token)) return;
      // A single CJK glyph is a legitimate token; latin needs >= 2 letters.
      if (token.length < (cjk ? 1 : 2)) return;
      tokens.add(token);
    }

    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final word = _cjkChar.hasMatch(ch) || _latinWord.hasMatch(ch);
      if (word) {
        buffer.write(ch);
      } else {
        flush(cjk: isCjk);
      }
    }
    flush(cjk: isCjk);
    return tokens;
  }

  static final RegExp _cjkChar =
      RegExp(r'[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]');
  static final RegExp _latinWord = RegExp(r'[A-Za-z0-9_]');

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

/// Result of pulling reasoning traces out of a raw assistant message.
class _ThinkingSplit {
  const _ThinkingSplit(this.thinking, this.cleaned);
  final String thinking;
  final String cleaned;
}

class _TeachingSections {
  const _TeachingSections(this.answer, this.explanation);

  final String answer;
  final String explanation;
}
