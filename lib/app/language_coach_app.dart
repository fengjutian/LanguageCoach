import 'package:flutter/material.dart';

import '../core/ai/conversation_engine.dart';
import '../core/model/app_settings.dart';
import '../features/home/home_page.dart';

class LanguageCoachApp extends StatefulWidget {
  const LanguageCoachApp({super.key});

  @override
  State<LanguageCoachApp> createState() => _LanguageCoachAppState();
}

class _LanguageCoachAppState extends State<LanguageCoachApp> {
  final settings = AppSettings();
  late final engine = ConversationEngine(settings: settings);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Language Coach',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff315c49),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff7f5ef),
        useMaterial3: true,
      ),
      home: HomePage(engine: engine, settings: settings),
    );
  }
}
