import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_page.dart';
import '../history/history_page.dart';
import '../practice/practice_page.dart';
import '../settings/settings_page.dart';
import 'application/home_navigation.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  String? _practicePrompt;

  void _startPractice(String prompt) {
    setState(() {
      _practicePrompt = prompt;
    });
    ref.read(homeTabProvider.notifier).state = HomeTab.chat;
  }

  @override
  Widget build(BuildContext context) {
    final index = homeTabIndex(ref.watch(homeTabProvider));
    final pages = [
      ChatPage(initialPrompt: _practicePrompt),
      PracticePage(onStart: _startPractice),
      const HistoryPage(),
      const SettingsPage(),
    ];
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: index, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) {
          ref.read(homeTabProvider.notifier).state = HomeTab.values[value];
          setState(() {});
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school),
            label: '练习',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: '历史'),
          NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
        ],
      ),
    );
  }
}
