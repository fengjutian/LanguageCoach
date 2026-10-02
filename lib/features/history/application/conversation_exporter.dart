import 'package:language_coach/core/models/chat_models.dart';

/// Pure markdown formatter for one conversation. Lives in `application/`
/// because the export pipeline is part of the history feature, not the
/// data layer — the data layer just hands us a title + a list of
/// [ChatMessage]s and we render.
class ConversationExporter {
  const ConversationExporter();

  /// Render [messages] into a markdown document. The header carries the
  /// title + timestamp; each message becomes a `### ` section with the
  /// role label and the rendered primary text + explanation.
  String render({
    required String title,
    required DateTime exportedAt,
    required List<ChatMessage> messages,
  }) {
    final buffer = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln('_Exported ${_formatTimestamp(exportedAt)}_')
      ..writeln()
      ..writeln('---')
      ..writeln();

    for (final message in messages) {
      buffer
        ..writeln('### ${_labelFor(message.role)}  ')
        ..writeln(_formatTimestamp(message.createdAt))
        ..writeln();

      final response = message.response;
      if (response != null) {
        if (response.primary.isNotEmpty) {
          buffer
            ..writeln('**${response.targetLanguage.toUpperCase()}**')
            ..writeln()
            ..writeln('> ${response.primary}')
            ..writeln();
        }
        if (response.explanation.isNotEmpty) {
          buffer
            ..writeln('**解释**')
            ..writeln()
            ..writeln(response.explanation)
            ..writeln();
        }
        if (response.alternatives.isNotEmpty) {
          buffer.writeln('**备选**');
          buffer.writeln();
          for (final alt in response.alternatives) {
            buffer.writeln('- $alt');
          }
          buffer.writeln();
        }
        if (response.keywords.isNotEmpty) {
          buffer.writeln('关键词: ${response.keywords.join(', ')}');
          buffer.writeln();
        }
      } else if (message.sourceText != null &&
          message.sourceText!.isNotEmpty) {
        buffer.writeln(message.sourceText!);
        buffer.writeln();
      }

      buffer.writeln('---');
      buffer.writeln();
    }

    return buffer.toString();
  }

  String _labelFor(MessageRole role) {
    switch (role) {
      case MessageRole.user:
        return '你';
      case MessageRole.assistant:
        return '教练';
      case MessageRole.error:
        return '错误';
    }
  }

  String _formatTimestamp(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  /// Suggest a filename for the exported markdown. Slug-ifies the title
  /// so the OS file picker shows something readable, falls back to a
  /// date-based name for empty / non-latin titles.
  String suggestFilename({required String title, required DateTime now}) {
    final slug = _slug(title);
    final base = slug.isEmpty ? 'conversation' : slug;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${base}_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}.md';
  }

  String _slug(String input) {
    // Keep ASCII alphanumerics + underscores + CJK characters; collapse
    // everything else (whitespace, punctuation, slashes) into a single
    // dash so the result is filename-safe on every platform.
    return input
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\u4e00-\u9fff-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }
}