import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_toast.dart';
import '../settings/application/settings_controller.dart';
import 'application/conversation_export_providers.dart';
import 'application/history_controller.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空所有对话？'),
        content: const Text('此操作不可撤销。所有历史消息与回显都会被永久删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(historyControllerProvider.notifier).deleteAll();
      ref.read(settingsControllerProvider.notifier).setLastConversationId(null);
      ref.read(historySearchQueryProvider.notifier).state = '';
      _searchController.clear();
    }
  }

  Future<void> _openConversation(String conversationId) async {
    ref
        .read(settingsControllerProvider.notifier)
        .setLastConversationId(conversationId);
    if (!mounted) return;
    AppToast.success(context, '已恢复该对话。请回到对话页查看。');
  }

  Future<void> _exportConversation(String conversationId) async {
    try {
      final path = await ref.read(
        exportConversationProvider(conversationId).future,
      );
      if (!mounted) return;
      AppToast.success(context, '已导出到 $path');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, '导出失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(historyControllerProvider);
    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('学习记录'),
          actions: [
            IconButton(
              tooltip: '清空全部',
              onPressed: _confirmClearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索对话标题或内容',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          ref.read(historySearchQueryProvider.notifier).state =
                              '';
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
              onChanged: (value) {
                ref.read(historySearchQueryProvider.notifier).state = value;
                setState(() {}); // refresh suffix icon visibility
              },
            ),
          ),
        ),
        conversations.when(
          data: (items) {
            if (items.isEmpty) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.forum_outlined,
                          size: 54, color: Colors.black38),
                      SizedBox(height: 12),
                      Text(
                        '还没有保存的对话',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '去对话页发一条消息试试',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              );
            }
            return SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return Dismissible(
                  key: ValueKey(item.id),
                  background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete_outline),
                  ),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) {
                    ref
                        .read(historyControllerProvider.notifier)
                        .deleteConversation(item.id);
                  },
                  child: ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(item.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle:
                        Text(item.preview.isEmpty ? '(无内容)' : item.preview),
                    trailing: Text(
                      _shortDate(item.updatedAt),
                      style: const TextStyle(color: Colors.black54),
                    ),
                    onTap: () => _openConversation(item.id),
                    onLongPress: () => _showItemMenu(item.id),
                  ),
                );
              },
            );
          },
          loading: () => const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('加载失败：$e')),
          ),
        ),
      ],
    );
  }

  String _shortDate(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> _showItemMenu(String conversationId) async {
    final action = await showModalBottomSheet<_HistoryItemAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出 / 分享'),
              onTap: () => Navigator.pop(ctx, _HistoryItemAction.export),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, _HistoryItemAction.delete),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _HistoryItemAction.export:
        await _exportConversation(conversationId);
      case _HistoryItemAction.delete:
        await ref
            .read(historyControllerProvider.notifier)
            .deleteConversation(conversationId);
    }
  }
}

enum _HistoryItemAction { export, delete }
