import 'dart:async';

import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/services/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// `AuthRepository.restore()` / `logout()` —— 存储路径必须**全程限时**。
///
/// 真实故障族：`SecureStore.getOrCreateDeviceId()` 内部会调原生 MethodChannel
/// （`BootLog.nativeDeviceId`）。通道对端不回应时 `invokeMethod` **既不返回也不
/// 抛异常**，而 `restore()` 位于**启动路径**上 —— 界面会永远停在启动页，
/// 既不进登录页也不报错。电视上没有 adb，用户拿不到任何诊断信息。
///
/// 因此降级方向必须统一为「当作未登录」：`restore()` 正常返回、
/// `isLoggedIn == false`，把用户送到登录页。
void main() {
  group('AuthRepository 存储路径限时（回归）', () {
    test('原生通道永不回应时，restore() 不得卡死', () async {
      final repo = AuthRepository(store: _HangingStore(hangDeviceId: true));

      // 上限 8 秒 + 余量。若限时逻辑被移除，这里会抛 TimeoutException，
      // 而不是「静默地一起卡住」——这正是要拦住的回归。
      await repo.restore().timeout(const Duration(seconds: 15));

      expect(repo.isLoggedIn, isFalse);
    });

    test('读取会话永不回应时，restore() 不得卡死', () async {
      final repo = AuthRepository(store: _HangingStore(hangReadSession: true));

      await repo.restore().timeout(const Duration(seconds: 15));

      expect(repo.isLoggedIn, isFalse);
    });

    test('清除会话永不回应时，logout() 仍应清空内存登录态', () async {
      final repo = AuthRepository(store: _HangingStore(hangClearSession: true));

      await repo.logout().timeout(const Duration(seconds: 15));

      expect(repo.isLoggedIn, isFalse);
      expect(repo.currentUser, isNull);
    });
  });
}

/// 模拟「原生通道 / 安全存储对端不回应」：对应方法返回一个**永不完成**的 Future。
///
/// 只覆写需要挂住的那一个方法；其余覆写成**不依赖插件**的即时返回，
/// 否则测试环境里 `super.getOrCreateDeviceId()` 会因 MethodChannel 无对端而抛
/// `MissingPluginException`，`restore()` 会提前 return —— 后面的 `readSession`
/// 挂起路径根本走不到，测试就变成「假通过」。
class _HangingStore extends SecureStore {
  _HangingStore({
    this.hangDeviceId = false,
    this.hangReadSession = false,
    this.hangClearSession = false,
  });

  /// 一个合法形态的 deviceId（契约要求 32 位小写 hex）。
  static const String _validDeviceId = '0123456789abcdef0123456789abcdef';

  final bool hangDeviceId;
  final bool hangReadSession;
  final bool hangClearSession;

  @override
  Future<String> getOrCreateDeviceId() {
    if (hangDeviceId) return Completer<String>().future;
    // 立刻返回合法值，让 restore() 能真正走到 readSession 那一步。
    return Future<String>.value(_validDeviceId);
  }

  @override
  Future<SessionRecord?> readSession() {
    if (hangReadSession) return Completer<SessionRecord?>().future;
    return super.readSession();
  }

  @override
  Future<void> clearSession() {
    if (hangClearSession) return Completer<void>().future;
    return super.clearSession();
  }
}
