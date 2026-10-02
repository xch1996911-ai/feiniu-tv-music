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
/// 只覆写需要挂住的那一个方法，其余继承真实实现（本测试不触碰它们）。
class _HangingStore extends SecureStore {
  _HangingStore({
    this.hangDeviceId = false,
    this.hangReadSession = false,
    this.hangClearSession = false,
  });

  final bool hangDeviceId;
  final bool hangReadSession;
  final bool hangClearSession;

  @override
  Future<String> getOrCreateDeviceId() {
    if (hangDeviceId) return Completer<String>().future;
    return super.getOrCreateDeviceId();
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
