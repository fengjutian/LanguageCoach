import 'package:flutter/material.dart';

import '../../core/ai/conversation_engine.dart';
import '../../core/model/app_settings.dart';
import '../chat/chat_page.dart';
import '../history/history_page.dart';
import '../settings/settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({required this.engine, required this.settings, super.key});
  final ConversationEngine engine;
  final AppSettings settings;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatPage(engine: widget.engine, settings: widget.settings),
      const HistoryPage(),
      SettingsPage(settings: widget.settings),
    ];
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: index, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '对话',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: '历史'),
          NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
        ],
      ),
    );
  }
}
