import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/home/home_page.dart';

class LanguageCoachApp extends ConsumerWidget {
  const LanguageCoachApp({super.key});

  static const _brandGreen = Color(0xff315c49);
  static const _appBackground = Color(0xfff2f7f3);
  static const _navigationBackground = Color(0xffe7f0e9);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _brandGreen,
      brightness: Brightness.light,
      surface: _appBackground,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Language Coach',
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: _appBackground,
        appBarTheme: const AppBarTheme(
          backgroundColor: _appBackground,
          surfaceTintColor: Colors.transparent,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _navigationBackground,
          indicatorColor: colorScheme.primaryContainer,
          surfaceTintColor: Colors.transparent,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
