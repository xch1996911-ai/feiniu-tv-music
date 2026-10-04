import 'package:flutter/services.dart';

/// 系统软键盘的**显式**唤起 / 收起，以及输入法可用性查询。
///
/// ## 为什么需要这条原生通道（真实故障：小米电视 S Pro 2025）
///
/// 用户实测：登录页能选中输入框，但按 OK **系统软键盘不弹出**，
/// NAS 地址 / 用户名 / 密码一个都输不进去 ⇒ 完全无法登录。
///
/// 系统键盘到底弹不弹，**不由 App 决定**：Flutter 的 `TextInputPlugin` 会调用
/// `InputMethodManager.showSoftInput`，但这依赖电视 ROM 里存在一个可用的输入法、
/// 且它愿意为「非触屏设备」显示。电视上没有 adb、看不到 logcat，
/// 因此应用侧要做三件事：
///
/// 1. **显式再唤一次**（部分 ROM 上 Flutter 的调用时机在焦点稳定之前，会失败）；
/// 2. **查询是否存在可用输入法**（用于诊断，也用于决定是否直接上应用内键盘）；
/// 3. **收起**（关闭键盘后不留断层，让 `viewInsets` 归零）。
///
/// ## 降级原则（比「成功」更重要）
/// 电视上没有调试通道，**任何一次输入法查询都不允许把登录页搞崩**：
/// 所有方法失败即返回 `null` / `false`，绝不抛异常。
/// 真正保证「用户一定能输入」的是应用内遥控器键盘
/// （`lib/ui/widgets/tv_keyboard.dart`），本类只是**尽量**用上系统键盘。
class TextInputBridge {
  /// 与 `MainActivity` 的引导通道同名（`feiniu/boot`）。
  ///
  /// ⚠️ 不新开通道名：本工程的原生桥接已经过实机验证，
  /// 多一条通道就多一份「某个电视 ROM 上注册失败」的风险。
  static const MethodChannel _channel = MethodChannel('feiniu/boot');

  /// 单次调用上限。超出即视为「该 ROM 不支持」，交给应用内键盘兜底。
  static const Duration _timeout = Duration(milliseconds: 600);

  /// 显式请求系统软键盘。返回是否**被系统接受**（不代表一定会显示）。
  static Future<bool> showSoftKeyboard() async {
    try {
      final bool? ok = await _channel
          .invokeMethod<bool>('showSoftKeyboard')
          .timeout(_timeout);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 收起系统软键盘。
  static Future<bool> hideSoftKeyboard() async {
    try {
      final bool? ok = await _channel
          .invokeMethod<bool>('hideSoftKeyboard')
          .timeout(_timeout);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 输入法可用性摘要（**非敏感**）：包含可用输入法数量与默认输入法包名。
  ///
  /// 用途：真机排障时能在屏幕/诊断页上读到「这台电视到底有没有输入法」，
  /// 而不是靠猜。不含任何凭据。
  static Future<String?> imeInfo() async {
    try {
      final String? info =
          await _channel.invokeMethod<String>('imeInfo').timeout(_timeout);
      return info;
    } catch (_) {
      return null;
    }
  }
}
