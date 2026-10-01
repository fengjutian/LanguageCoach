import 'package:flutter/material.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const CustomScrollView(
      slivers: [
        SliverAppBar.large(title: Text('学习记录')),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.forum_outlined, size: 54, color: Colors.black38),
                SizedBox(height: 12),
                Text(
                  '还没有保存的对话',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 6),
                Text(
                  'SQLite 持久化将在下一实现批次接入',
                  style: TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
