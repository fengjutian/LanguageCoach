import 'package:flutter/foundation.dart';

import 'app_settings.dart';

/// Complete conversation metadata. The chat controller needs the target
/// language to restore a session *before* the first reply is requested, so a
/// 3-field record (id/title/updatedAt) is not enough — the language used to
/// live in the `conversations` table but was never read back.
@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.preferredLanguage,
    required this.targetLanguage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;

  /// Global default that was active when the conversation was created.
  final CoachLanguage preferredLanguage;

  /// Per-conversation learning target, restored on open. New conversations
  /// seed this from the global default and it changes only when the user
  /// switches the in-chat selector.
  final CoachLanguage targetLanguage;

  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation copyWith({
    String? title,
    CoachLanguage? preferredLanguage,
    CoachLanguage? targetLanguage,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      // createdAt is deliberately not copied: language/title updates must
      // never move the creation timestamp.
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
