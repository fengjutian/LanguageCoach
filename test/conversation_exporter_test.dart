import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/conversation_repository.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/features/history/application/conversation_export_service.dart';
import 'package:language_coach/features/history/application/conversation_exporter.dart';

void main() {
  group('ConversationExporter', () {
    test('renders header + per-message sections', () {
      const exporter = ConversationExporter();
      final md = exporter.render(
        title: '天气会话',
        exportedAt: DateTime(2026, 10, 2, 14, 30),
        messages: [
          ChatMessage(
            id: 'u1',
            role: MessageRole.user,
            createdAt: DateTime(2026, 10, 2, 14, 0),
            sourceText: '今天下雨',
          ),
          ChatMessage(
            id: 'a1',
            role: MessageRole.assistant,
            createdAt: DateTime(2026, 10, 2, 14, 0, 30),
            response: CoachResponse(
              intent: CoachIntent.conversation,
              sourceLanguage: 'zh',
              targetLanguage: 'en',
              primary: "It's raining today.",
              alternatives: const ["It's rainy today."],
              explanation: '描述当前天气的日常表达。',
              sentences: const [CoachSentence(id: 's1', text: "It's raining today.")],
              keywords: const ['rain', 'today'],
            ),
          ),
        ],
      );
      expect(md, contains('# 天气会话'));
      expect(md, contains('### 你'));
      expect(md, contains('### 教练'));
      expect(md, contains('> It\'s raining today.'));
      expect(md, contains('描述当前天气的日常表达'));
      expect(md, contains('- It\'s rainy today.'));
      expect(md, contains('关键词: rain, today'));
    });

    test('suggestFilename slug-ifies the title and stamps the time', () {
      const exporter = ConversationExporter();
      final filename = exporter.suggestFilename(
        title: '天气 / 会话 !!',
        now: DateTime(2026, 10, 2, 9, 5),
      );
      // Non-ASCII alphanumerics pass through unchanged; runs of
      // non-filename characters collapse into a single dash.
      expect(filename, '天气-会话_20261002_0905.md');
    });

    test('suggestFilename falls back to "conversation" for empty titles', () {
      const exporter = ConversationExporter();
      final filename = exporter.suggestFilename(
        title: '!!!',
        now: DateTime(2026, 1, 2, 3, 4),
      );
      expect(filename, 'conversation_20260102_0304.md');
    });
  });

  group('ConversationExportService', () {
    late _FakeRepository repo;
    late _FakeShare share;
    late RecordingDirectory dir;
    late ConversationExportService service;

    setUp(() {
      repo = _FakeRepository();
      share = _FakeShare();
      dir = RecordingDirectory();
      service = ConversationExportService(
        repository: repo,
        exporter: const ConversationExporter(),
        share: share,
        tempDirectoryProvider: () async => dir.delegate,
      );
    });

    test('export writes a file and asks the share service to surface it',
        () async {
      repo.putConversation('c1', title: '天气会话');
      repo.putMessage('c1', ChatMessage(
        id: 'u1',
        role: MessageRole.user,
        createdAt: DateTime(2026, 10, 2),
        sourceText: 'hi',
      ));

      final path = await service.export('c1',
          now: DateTime(2026, 10, 2, 14, 30));

      expect(path, isNotEmpty);
      expect(share.lastPath, path);
      expect(share.lastSubject, '天气会话');
      final file = File(path);
      expect(file.existsSync(), isTrue);
      final body = await file.readAsString();
      expect(body, contains('# 天气会话'));
      expect(body, contains('hi'));
    });

    test('export throws when the conversation id is unknown', () async {
      expect(() => service.export('missing'), throwsStateError);
    });
  });
}

class _FakeRepository implements ConversationRepository {
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, _Meta> _meta = {};

  void putConversation(String id, {required String title}) {
    _meta[id] = _Meta(id: id, title: title, updatedAt: DateTime(2026, 10, 2));
  }

  void putMessage(String conversationId, ChatMessage message) {
    _messages.putIfAbsent(conversationId, () => []).add(message);
  }

  @override
  Future<void> ensureConversation(
    String id, {
    String? title,
    CoachLanguage? preferredLanguage,
    CoachLanguage? targetLanguage,
    DateTime? createdAt,
  }) async {
    _meta.putIfAbsent(
      id,
      () => _Meta(
        id: id,
        title: title ?? '对话',
        updatedAt: createdAt ?? DateTime.now(),
      ),
    );
  }

  @override
  Future<void> updateTitle(String conversationId, String title) async {
    final meta = _meta[conversationId];
    if (meta != null) {
      _meta[conversationId] = _Meta(
        id: meta.id,
        title: title,
        updatedAt: meta.updatedAt,
      );
    }
  }

  @override
  Future<({String id, String title, DateTime updatedAt})?> findById(
      String conversationId) async {
    final meta = _meta[conversationId];
    if (meta == null) return null;
    return (id: meta.id, title: meta.title, updatedAt: meta.updatedAt);
  }

  @override
  Future<List<ChatMessage>> messagesFor(String conversationId) async {
    return List<ChatMessage>.from(_messages[conversationId] ?? const []);
  }

  @override
  Future<String> appendMessage({
    required String conversationId,
    required ChatMessage message,
  }) async {
    putMessage(conversationId, message);
    return message.id;
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _meta.remove(conversationId);
    _messages.remove(conversationId);
  }

  @override
  Future<void> deleteAllConversations() async {
    _meta.clear();
    _messages.clear();
  }

  @override
  Future<List<({String id, String preview, DateTime updatedAt})>>
      recentConversations({int limit = 50, String? query}) async {
    return _meta.values
        .map((m) => (
              id: m.id,
              preview: '',
              updatedAt: m.updatedAt,
            ))
        .toList();
  }
}

class _Meta {
  _Meta({required this.id, required this.title, required this.updatedAt});
  final String id;
  final String title;
  final DateTime updatedAt;
}

class _FakeShare implements ShareService {
  String? lastPath;
  String? lastSubject;
  String? lastText;

  @override
  Future<void> shareFile({
    required String path,
    String? text,
    String? subject,
  }) async {
    lastPath = path;
    lastSubject = subject;
    lastText = text;
  }
}

class RecordingDirectory {
  RecordingDirectory()
      : delegate = Directory.systemTemp.createTempSync('export_test_');
  final Directory delegate;
  final List<String> writtenPaths = [];

  String get path => delegate.path;
}

// Kept for IDE reference.
