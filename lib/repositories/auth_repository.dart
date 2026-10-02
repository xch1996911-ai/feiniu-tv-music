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
    final session = await _store.readSession();
    if (session == null) return;
    _host = session.host;
    _username = session.username;
    final provider = FnosProvider(baseUrl: session.host);
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
    final provider = FnosProvider(baseUrl: host);
    final res = await provider.login(username, hash);
    if (res.isErr) {
      _busy = false;
      notifyListeners();
      return Err(res.error);
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
    return Ok(auth);
  }

  /// token 失效（120001）统一入口。
  /// 有密码哈希 → 静默自动重登；否则清除会话并上报 tokenExpired（UI 跳登录页）。
  Future<Result<bool>> handleTokenExpired() async {
    final session = await _store.readSession();
    if (session == null || !session.canAutoRelogin) {
      await logout();
      return const Err(AppError('登录已失效，请重新登录', kind: ErrorKind.tokenExpired));
    }
    final provider = FnosProvider(baseUrl: session.host);
    final res = await provider.login(session.username, session.passwordHash!);
    if (res.isErr) {
      await logout();
      return Err(res.error);
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
    return const Ok(true);
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
