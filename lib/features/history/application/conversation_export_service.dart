import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/ai/conversation_repository.dart';
import 'conversation_exporter.dart';

/// Thin seam over [share_plus] so tests can swap it for a fake that
/// captures the files it would have shared. The default implementation
/// is just a [Share.shareXFiles] wrapper.
abstract interface class ShareService {
  Future<void> shareFile({
    required String path,
    String? text,
    String? subject,
  });
}

class SystemShareService implements ShareService {
  const SystemShareService();

  @override
  Future<void> shareFile({
    required String path,
    String? text,
    String? subject,
  }) async {
    await Share.shareXFiles(
      [XFile(path)],
      subject: subject,
      text: text,
    );
  }
}

/// End-to-end export pipeline: load the conversation + messages from
/// the [ConversationRepository], render the markdown, drop the file in
/// the app's cache directory, then surface it through [ShareService].
///
/// Kept intentionally small — the formatter is a separate class
/// ([ConversationExporter]) so this stays a thin orchestrator that's
/// easy to drive from a Riverpod provider and easy to fake in tests.
class ConversationExportService {
  ConversationExportService({
    required ConversationRepository repository,
    required ConversationExporter exporter,
    required ShareService share,
    Future<Directory> Function()? tempDirectoryProvider,
  })  : _repository = repository,
        _exporter = exporter,
        _share = share,
        _tempDirectoryProvider = tempDirectoryProvider ?? getTemporaryDirectory;

  final ConversationRepository _repository;
  final ConversationExporter _exporter;
  final ShareService _share;
  final Future<Directory> Function() _tempDirectoryProvider;

  /// Render + write + share. Returns the absolute path to the markdown
  /// file so callers can show a confirmation toast that points back to
  /// the file.
  Future<String> export(String conversationId, {DateTime? now}) async {
    final meta = await _repository.findById(conversationId);
    if (meta == null) {
      throw StateError('conversation $conversationId not found');
    }
    final messages = await _repository.messagesFor(conversationId);
    final stamp = now ?? DateTime.now();
    final markdown = _exporter.render(
      title: meta.title,
      exportedAt: stamp,
      messages: messages,
    );
    final filename = _exporter.suggestFilename(title: meta.title, now: stamp);
    final dir = await _tempDirectoryProvider();
    final file = File(p.join(dir.path, filename));
    await file.writeAsString(markdown);

    await _share.shareFile(
      path: file.path,
      subject: meta.title,
      text: '导出于 ${_formatTimestamp(stamp)}',
    );
    return file.path;
  }

  String _formatTimestamp(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}