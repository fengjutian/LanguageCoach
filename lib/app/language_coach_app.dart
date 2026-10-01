import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/home/home_page.dart';

class LanguageCoachApp extends StatelessWidget {
  const LanguageCoachApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      home: const HomePage(),
    );
  }
}