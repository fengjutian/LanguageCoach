import 'package:language_coach/core/ai/conversation_repository.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Test double for [ConversationRepository] that lives entirely in memory.
/// Used by widget / controller tests so they don't need sqflite_native
/// bindings to run on the host VM. Mirrors the SQLite semantics for the
/// operations P0-3 actually exercises (append, messagesFor, delete, search).
class InMemoryConversationRepository implements ConversationRepository {
  InMemoryConversationRepository();

  final _conversations = <String, _ConversationRecord>{};

  @override
  Future<void> ensureConversation(
    String id, {
    String? title,
    CoachLanguage? preferredLanguage,
    CoachLanguage? targetLanguage,
    DateTime? createdAt,
  }) async {
    final existing = _conversations[id];
    final now = DateTime.now();
    if (existing == null) {
      _conversations[id] = _ConversationRecord(
        title: title ?? _defaultTitle(now),
        preferredLanguage: preferredLanguage,
        targetLanguage: targetLanguage,
        createdAt: createdAt ?? now,
        updatedAt: now,
      );
    } else if (title != null) {
      existing.title = title;
      existing.updatedAt = now;
    }
  }

  @override
  Future<void> updateTitle(String conversationId, String title) async {
    final c = _conversations[conversationId];
    if (c == null) return;
    c.title = title;
    c.updatedAt = DateTime.now();
  }

  @override
  Future<({String id, String title, DateTime updatedAt})?> findById(
      String conversationId) async {
    final c = _conversations[conversationId];
    if (c == null) return null;
    return (
      id: conversationId,
      title: c.title,
      updatedAt: c.updatedAt,
    );
  }

  @override
  Future<List<ChatMessage>> messagesFor(String conversationId) async {
    final c = _conversations[conversationId];
    if (c == null) return const <ChatMessage>[];
    final result = <ChatMessage>[];
    for (final entry in c.messages.entries) {
      result.add(entry.value);
    }
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  @override
  Future<String> appendMessage({
    required String conversationId,
    required ChatMessage message,
  }) async {
    await ensureConversation(conversationId);
    final c = _conversations[conversationId]!;
    c.messages[message.id] = message;
    c.updatedAt = DateTime.now();
    return message.id;
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _conversations.remove(conversationId);
  }

  @override
  Future<void> deleteAllConversations() async {
    _conversations.clear();
  }

  @override
  Future<List<({String id, String preview, DateTime updatedAt})>>
      recentConversations({int limit = 50, String? query}) async {
    final all = _conversations.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    final filtered = <MapEntry<String, _ConversationRecord>>[];
    for (final entry in all) {
      if (query == null || query.isEmpty) {
        filtered.add(entry);
      } else {
        final needle = query.toLowerCase();
        final inTitle = entry.value.title.toLowerCase().contains(needle);
        final inMessages = entry.value.messages.values.any(
          (m) => (m.sourceText ?? '').toLowerCase().contains(needle),
        );
        if (inTitle || inMessages) filtered.add(entry);
      }
      if (filtered.length >= limit) break;
    }
    return filtered.map((entry) {
      final userMsg = entry.value.messages.values
          .where((m) => m.role == MessageRole.user)
          .toList();
      userMsg.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return (
        id: entry.key,
        preview: userMsg.isEmpty ? '' : (userMsg.first.sourceText ?? ''),
        updatedAt: entry.value.updatedAt,
      );
    }).toList();
  }
}

class _ConversationRecord {
  _ConversationRecord({
    required this.title,
    required this.preferredLanguage,
    required this.targetLanguage,
    required this.createdAt,
    required this.updatedAt,
  });
  String title;
  final CoachLanguage? preferredLanguage;
  final CoachLanguage? targetLanguage;
  final DateTime createdAt;
  DateTime updatedAt;
  final Map<String, ChatMessage> messages = <String, ChatMessage>{};
}

String _defaultTitle(DateTime now) {
  final mm = now.month.toString().padLeft(2, '0');
  final dd = now.day.toString().padLeft(2, '0');
  final hh = now.hour.toString().padLeft(2, '0');
  final mi = now.minute.toString().padLeft(2, '0');
  return '对话 $mm-$dd $hh:$mi';
}

/// Test double for [SettingsRepository] mirroring the SQLite JSON-on-disk
/// behaviour without any platform channel.
class InMemorySettingsRepository implements SettingsRepository {
  InMemorySettingsRepository();

  final Map<String, Object?> _values = <String, Object?>{};

  @override
  Future<Map<Object?, Object?>> loadRaw() async {
    return Map<Object?, Object?>.from(_values);
  }

  @override
  Future<void> saveRaw(Map<Object?, Object?> raw) async {
    for (final entry in raw.entries) {
      _values[entry.key.toString()] = entry.value;
    }
  }

  Future<void> clearAll() async => _values.clear();
}
