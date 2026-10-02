import 'package:flutter/material.dart';

/// 全局统一的信息提示入口。
///
/// 项目里所有瞬态提示（成功 / 失败 / 错误 / 一般信息）都从这里发出，
/// 避免业务侧直接写 `ScaffoldMessenger.of(context).showSnackBar(...)`，
/// 后续要换样式、时长、埋点都只动这里。
///
/// 真正的"询问型"弹窗（需要用户做决定的）请继续用 `showDialog` + `AlertDialog`。
class AppToast {
  AppToast._();

  /// 短信息（默认 2 秒）。
  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 成功 / 一般通知（默认 2 秒）。
  static void success(BuildContext context, String message) =>
      show(context, message);

  /// 错误 / 失败提示（默认 3 秒）。
  static void error(BuildContext context, String message) =>
      show(context, message, duration: const Duration(seconds: 3));
}