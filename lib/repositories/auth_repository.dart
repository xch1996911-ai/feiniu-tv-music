import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/boot_log.dart';
import '../core/exceptions.dart';
import '../core/result.dart';
import '../core/log.dart';
import '../domain/user.dart';
import '../servers/fnos/fnos_auth.dart';
import '../servers/fnos/fnos_client.dart';
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
  /// 设备标识读取（原生通道 / 安全存储）的单步上限。
  static const Duration _deviceIdTimeout = Duration(seconds: 8);

  /// 会话持久化（安全存储写入）的单步上限。
  static const Duration _storeTimeout = Duration(seconds: 8);

  /// 登录请求上限。客户端本身已设 connect 8s / receive 30s，这里再兜一层，
  /// 防止「服务端持续吐数据但永不结束」这类收不到超时的情况。
  static const Duration _loginTimeout = Duration(seconds: 40);

  /// 免登录探测上限。
  static const Duration _probeTimeout = Duration(seconds: 12);

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
  ///
  /// ## ⚠️ 每一步都必须有硬超时（实机故障复盘）
  ///
  /// 海信电视上登录时界面**永远停在「连接中」**，既不成功也不报错。原因是
  /// 这条路径上有三个都可能「不返回、也不抛异常」的点：
  /// 1. `SecureStore.getOrCreateDeviceId()` —— 内含 MethodChannel 调用，
  ///    通道对端不回应时 `invokeMethod` 永不完成；
  /// 2. `FnosProvider.login()` —— Dio 的 `receiveTimeout` 只约束「两个数据包
  ///    之间的间隔」，服务端持续吐字节但永不结束时不触发；
  /// 3. `SecureStore.saveSession()` —— **登录其实已经成功**，却卡在写安全存储，
  ///    界面同样停在「连接中」（本函数返回前不会调用 onLoggedIn）。
  ///
  /// 电视上没有 adb，屏幕是唯一的信息出口 —— 「无限等待」比「明确报错」更糟。
  /// 因此三步各自限时，并把阶段名通过 [onStage] 回报给 UI 显示。
  ///
  /// [onStage] 是诊断用的可选回调（UI 把它显示在按钮下方），
  /// 不传则行为与从前一致。
  Future<Result<AuthResult>> login({
    required String host,
    required String username,
    required String password,
    required bool rememberPassword,
    void Function(String stage)? onStage,
  }) async {
    _busy = true;
    notifyListeners();

    onStage?.call('读取设备标识…');
    final hash = FnosAuth.hashPassword(password);
    final deviceIdRes = await _resolveDeviceId();
    if (deviceIdRes.isErr) {
      _busy = false;
      notifyListeners();
      return Result.err(deviceIdRes.error);
    }
    // 契约：deviceId 必须是 32 位 hex 且持久化复用，不允许每次启动重新生成。
    final deviceId = deviceIdRes.value;

    onStage?.call('请求登录…');
    BootLog.mark('登录·发出密码登录请求 ${Log.redactHost(host)}');
    final provider = FnosProvider(baseUrl: host, deviceId: deviceId);

    final res = await _loginWithTimeout(provider, username, hash, deviceId);
    if (res.isErr) {
      _busy = false;
      notifyListeners();
      BootLog.mark('登录·失败 ${res.error.kind.name}');
      return Result.err(res.error);
    }

    final auth = res.value;
    provider.setToken(auth.token);
    _provider = provider;
    _host = host;
    _username = username;
    _currentUser = auth.user;

    onStage?.call('保存会话…');
    try {
      await _store
          .saveSession(SessionRecord(
            host: host,
            username: username,
            token: auth.token,
            // 仅当开启「记住密码」时保存 sha256 哈希（非明文）；用于 token 失效自动重登。
            passwordHash: rememberPassword ? hash : null,
          ))
          .timeout(_storeTimeout);
      BootLog.mark('登录·会话已持久化');
    } catch (e) {
      // 没落盘不影响本次使用（provider 已在内存里），只是下次启动要重新登录。
      // 绝不能因为存储问题把已经登录成功的用户挡在门外。
      Log.w('会话持久化失败或超时，本次登录仍然有效：$e');
      BootLog.mark('登录·会话持久化失败（本次仍可用）');
    }

    Log.i('登录成功 user=${Log.redactUser(username)} remember=$rememberPassword');
    _busy = false;
    notifyListeners();
    return Result.ok(auth);
  }

  /// 读取（或首次生成）deviceId，**带硬超时**。
  ///
  /// ⚠️ 内部含 MethodChannel 调用（原生 `SharedPreferences`）。通道对端不回应的
  /// 情况下 `invokeMethod` **既不返回也不抛异常**，没有超时就会永远停在「连接中」。
  Future<Result<String>> _resolveDeviceId() async {
    try {
      final id = await _store.getOrCreateDeviceId().timeout(_deviceIdTimeout);
      BootLog.mark('登录·设备标识就绪');
      return Result.ok(id);
    } on TimeoutException {
      BootLog.mark('登录·读取设备标识超时（${_deviceIdTimeout.inSeconds}s）');
      return Result.err(AppError(
        '读取设备标识超时（${_deviceIdTimeout.inSeconds} 秒无响应）',
        kind: ErrorKind.unknown,
      ));
    } catch (e, st) {
      BootLog.mark('登录·读取设备标识失败：$e');
      return Result.err(AppError('读取设备标识失败：$e',
          kind: ErrorKind.unknown, cause: e, stack: st));
    }
  }

  /// 发一次密码登录请求，**带硬超时**；超时也走 [Result] 而不是抛异常，
  /// 让调用方只有一条成功/失败路径。
  Future<Result<AuthResult>> _loginWithTimeout(
    FnosProvider provider,
    String username,
    String hash,
    String deviceId,
  ) async {
    try {
      return await provider
          .login(username, hash, deviceId: deviceId)
          .timeout(_loginTimeout);
    } on TimeoutException {
      BootLog.mark('登录·请求超时（${_loginTimeout.inSeconds}s）');
      return Result.err(AppError(
        '登录请求超时（${_loginTimeout.inSeconds} 秒无响应）：请检查 NAS 地址与网络',
        kind: ErrorKind.network,
      ));
    }
  }

  /// 免登录连通性探测：请求 `initialization/state`（官方前端同样匿名调用，
  /// 见 `fnOS_API_真实契约.md`）。
  ///
  /// 用途：把「地址/网络不通」与「凭据不对」彻底分开。电视上没有 adb，
  /// 这个动作是唯一能在**屏幕上**直接读出网络结论的手段。
  ///
  /// [adapter] 仅供单元测试注入离线适配器；生产路径为 null。
  Future<Result<String>> probe(
    String host, {
    HttpClientAdapter? adapter,
  }) async {
    final url = FnosClient.normalizeBaseUrl(host);
    final shown = Log.redactHost(url);
    try {
      final provider = FnosProvider(baseUrl: url, adapter: adapter);
      final res = await provider.checkConnection().timeout(_probeTimeout);
      if (res.isErr) {
        return Result.err(AppError(
          '${res.error.message} · $shown',
          kind: res.error.kind,
          cause: res.error.cause,
        ));
      }
      return Result.ok('连通正常 · $shown');
    } on TimeoutException {
      return Result.err(AppError('探测超时（$shown 无响应）',
          kind: ErrorKind.network));
    } catch (e, st) {
      return Result.err(AppError('探测失败：$e',
          kind: ErrorKind.network, cause: e, stack: st));
    }
  }

  /// 归一化用户输入的 NAS 地址（补 scheme、去尾斜杠）。
  ///
  /// UI 需要显示「实际将要请求的地址」，但不能直接依赖 `servers/fnos/*`
  /// （分层约定），故在此暴露一层。
  String normalizeHost(String host) => FnosClient.normalizeBaseUrl(host);

  /// token 失效（Cookie 缺失/过期 → HTTP 401 + code 99999）统一入口。
  ///
  /// 注意与 `120001` 的区别：`99999` 是 token Cookie 失效，可用已存密码哈希静默重登；
  /// `120001` 是凭据错误，必须让用户重新输入（见 [FnosErrorCodes]）。
  ///
  /// 与 [login] 同理，这里也全部带超时：本方法由数据请求失败时触发，
  /// 一旦挂住，用户看到的是「点了列表一直转圈」且永远没有结论。
  Future<Result<bool>> handleTokenExpired() async {
    SessionRecord? session;
    try {
      session = await _store.readSession().timeout(_deviceIdTimeout);
    } catch (e) {
      Log.w('读取会话失败/超时，按未登录处理：$e');
      session = null;
    }
    if (session == null || !session.canAutoRelogin) {
      await logout();
      return const Result.err(AppError('登录已失效，请重新登录', kind: ErrorKind.tokenExpired));
    }
    // 重登必须复用同一个 deviceId（存放在独立 key，登出不会清除）。
    try {
      final deviceId =
          await _store.getOrCreateDeviceId().timeout(_deviceIdTimeout);
      final provider = FnosProvider(baseUrl: session.host, deviceId: deviceId);
      final res = await provider
          .login(session.username, session.passwordHash!, deviceId: deviceId)
          .timeout(_loginTimeout);
      if (res.isErr) {
        await logout();
        return Result.err(res.error);
      }
      provider.setToken(res.value.token);
      _provider = provider;
      _currentUser = res.value.user;
      await _store
          .saveSession(SessionRecord(
            host: session.host,
            username: session.username,
            token: res.value.token,
            passwordHash: session.passwordHash,
          ))
          .timeout(_storeTimeout);
      Log.i('token 失效已自动重登 user=${Log.redactUser(session.username)}');
      notifyListeners();
      return const Result.ok(true);
    } on TimeoutException {
      await logout();
      return const Result.err(AppError('自动重登超时，请重新登录',
          kind: ErrorKind.network));
    } catch (e) {
      await logout();
      return Result.err(
          AppError('自动重登失败：$e', kind: ErrorKind.network, cause: e));
    }
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
