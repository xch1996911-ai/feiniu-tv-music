import 'package:flutter/material.dart';

import '../core/exceptions.dart';
import '../core/result.dart';
import '../core/log.dart';
import '../domain/user.dart';
import '../servers/fnos/fnos_auth.dart';
import '../servers/fnos/fnos_provider.dart';
import '../servers/music_server_provider.dart';
import '../services/secure_store.dart';

/// 认证与会话仓储。
///
/// 职责：
/// - 登录（sha256 密码）、持久化会话（token + 可选密码哈希）。
/// - 启动恢复（不主动联网，仅重建 provider）。
/// - token 失效（120001）统一处理：有密码哈希则自动重登，否则回登录页。
/// - 作为可观察状态源（ChangeNotifier），UI 通过 Provider 监听登录态。
class AuthRepository extends ChangeNotifier {
  final SecureStore _store;
  MusicServerProvider? _provider;
  User? _currentUser;
  String? _host;
  String? _username;
  bool _busy = false;

  AuthRepository({SecureStore? store}) : _store = store ?? SecureStore();

  MusicServerProvider? get provider => _provider;
  User? get currentUser => _currentUser;
  String? get host => _host;
  String? get username => _username;
  bool get busy => _busy;

  /// 已登录 = 已持有可用的 provider（其内已注入 token）。
  bool get isLoggedIn => _provider != null;

  /// 启动时恢复会话：若存在持久化 token，则重建 provider 并设为已登录（惰性，不主动联网）。
  Future<void> restore() async {
    // deviceId 与登录态无关，独立持久化：即使当前无会话也先准备好，
    // 保证首次登录时能拿到稳定值（契约要求「生成一次后复用」）。
    final deviceId = await _store.getOrCreateDeviceId();
    final session = await _store.readSession();
    if (session == null) return;
    _host = session.host;
    _username = session.username;
    final provider = FnosProvider(baseUrl: session.host, deviceId: deviceId);
    provider.setToken(session.token);
    _provider = provider;
    Log.i('恢复会话 host=${Log.redactHost(session.host)} user=${Log.redactUser(session.username)}');
    notifyListeners();
  }

  /// 登录。密码在本地计算 sha256 后才上传，明文不离开本机。
  Future<Result<AuthResult>> login({
    required String host,
    required String username,
    required String password,
    required bool rememberPassword,
  }) async {
    _busy = true;
    notifyListeners();

    final hash = FnosAuth.hashPassword(password);
    // 契约：deviceId 必须是 32 位 hex 且持久化复用，不允许每次启动重新生成。
    final deviceId = await _store.getOrCreateDeviceId();
    final provider = FnosProvider(baseUrl: host, deviceId: deviceId);
    final res = await provider.login(username, hash, deviceId: deviceId);
    if (res.isErr) {
      _busy = false;
      notifyListeners();
      return Result.err(res.error);
    }

    final auth = res.value;
    provider.setToken(auth.token);
    _provider = provider;
    _host = host;
    _username = username;
    _currentUser = auth.user;

    await _store.saveSession(SessionRecord(
      host: host,
      username: username,
      token: auth.token,
      // 仅当开启「记住密码」时保存 sha256 哈希（非明文）；用于 token 失效自动重登。
      passwordHash: rememberPassword ? hash : null,
    ));
    Log.i('登录成功 user=${Log.redactUser(username)} remember=$rememberPassword');
    _busy = false;
    notifyListeners();
    return Result.ok(auth);
  }

  /// token 失效（Cookie 缺失/过期 → HTTP 401 + code 99999）统一入口。
  ///
  /// 注意与 `120001` 的区别：`99999` 是 token Cookie 失效，可用已存密码哈希静默重登；
  /// `120001` 是凭据错误，必须让用户重新输入（见 [FnosErrorCodes]）。
  Future<Result<bool>> handleTokenExpired() async {
    final session = await _store.readSession();
    if (session == null || !session.canAutoRelogin) {
      await logout();
      return const Result.err(AppError('登录已失效，请重新登录', kind: ErrorKind.tokenExpired));
    }
    // 重登必须复用同一个 deviceId（存放在独立 key，登出不会清除）。
    final deviceId = await _store.getOrCreateDeviceId();
    final provider = FnosProvider(baseUrl: session.host, deviceId: deviceId);
    final res =
        await provider.login(session.username, session.passwordHash!, deviceId: deviceId);
    if (res.isErr) {
      await logout();
      return Result.err(res.error);
    }
    provider.setToken(res.value.token);
    _provider = provider;
    _currentUser = res.value.user;
    await _store.saveSession(SessionRecord(
      host: session.host,
      username: session.username,
      token: res.value.token,
      passwordHash: session.passwordHash,
    ));
    Log.i('token 失效已自动重登 user=${Log.redactUser(session.username)}');
    notifyListeners();
    return const Result.ok(true);
  }

  Future<void> logout() async {
    await _store.clearSession();
    _provider = null;
    _currentUser = null;
    _host = null;
    _username = null;
    notifyListeners();
  }
}
