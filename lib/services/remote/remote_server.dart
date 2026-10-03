import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/branding.dart';
import '../../core/diagnostics.dart';
import '../../core/log.dart';
import '../../domain/track.dart';
import '../../playback/playback_control.dart';
import '../../repositories/library_repository.dart';
import '../../repositories/local_library_repository.dart';
import '../../repositories/music_repository.dart';
import 'qr_code.dart';
import 'remote_page.dart';

/// 手机遥控的配对与会话（**纯逻辑，可单测，不碰网络**）。
///
/// ## 安全模型（需求 §七.7）
///
/// | 项目 | 做法 |
/// |---|---|
/// | 配对码 | 6 位、**一次性**、默认 5 分钟有效；用一次即失效 |
/// | 会话凭证 | 配对成功后下发 32 位十六进制随机串（`Random.secure()`） |
/// | 有效期 | 12 小时，超时需重新配对 |
/// | 并发会话 | **只允许一个**；新配对顶掉旧会话（需求 §七.6） |
/// | 持久化 | **不落盘**。App 关闭 / 退出登录 / 主动解除 → 立即失效 |
/// | 日志 | 配对码与凭证**绝不写日志**（只记「已配对/已失效」这类事件） |
///
/// 配对码刻意用「无歧义字符集」（去掉 0/O/1/I/L），因为它是**手输兜底**：
/// 二维码扫不出来时用户要照着屏幕敲。
class RemotePairingManager {
  /// 配对码字符集（去掉了 0 O 1 I L 这些容易被读错的字符）。
  static const String codeAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

  static const int codeLength = 6;

  /// 配对码有效期。
  static Duration pairingTtl = const Duration(minutes: 5);

  /// 会话有效期。
  static Duration sessionTtl = const Duration(hours: 12);

  RemotePairingManager({Random? random})
      : _random = random ?? Random.secure();

  final Random _random;

  String? _code;
  DateTime? _codeExpiresAt;

  String? _sessionToken;
  String? _sessionLabel;
  DateTime? _sessionExpiresAt;

  /// 已处理过的命令 id（去重，防止网络重试导致重复切歌）。
  final List<String> _seenCommandIds = <String>[];

  static const int _maxSeenCommands = 64;

  /// 当前配对码（未生成或已过期时为 null）。
  String? get pairingCode {
    final String? c = _code;
    final DateTime? e = _codeExpiresAt;
    if (c == null || e == null) return null;
    if (DateTime.now().isAfter(e)) return null;
    return c;
  }

  DateTime? get pairingCodeExpiresAt => pairingCode == null ? null : _codeExpiresAt;

  /// 当前是否有已配对的手机。
  bool get isPaired {
    final DateTime? e = _sessionExpiresAt;
    if (_sessionToken == null || e == null) return false;
    if (DateTime.now().isAfter(e)) {
      return false;
    }
    return true;
  }

  /// 已配对手机的名字（用于电视端显示「iPhone 15 已连接」）。
  String? get sessionLabel => isPaired ? _sessionLabel : null;

  /// 生成（或刷新）配对码。老的码立即失效。
  String regenerateCode() {
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < codeLength; i++) {
      buf.write(codeAlphabet[_random.nextInt(codeAlphabet.length)]);
    }
    _code = buf.toString();
    _codeExpiresAt = DateTime.now().add(pairingTtl);
    // 新码意味着「要重新配对」→ 旧会话作废（需求 §七.6：新会话替换旧会话）
    if (_sessionToken != null) {
      _sessionToken = null;
      _sessionLabel = null;
      _sessionExpiresAt = null;
      Diagnostics.event('遥控：重新生成配对码，旧手机会话已作废');
    }
    Diagnostics.note('手机遥控', '等待配对（配对码 ${pairingTtl.inMinutes} 分钟内有效）');
    return _code!;
  }

  /// 用配对码换取会话凭证。失败返回 null（配对码错误/过期/已用过）。
  String? pair({required String code, String? label}) {
    final String? expected = pairingCode;
    if (expected == null) {
      Diagnostics.event('遥控配对失败：配对码已过期或未生成');
      return null;
    }
    if (code.trim().toUpperCase() != expected) {
      Diagnostics.event('遥控配对失败：配对码不匹配');
      return null;
    }
    // 一次性：立刻作废
    _code = null;
    _codeExpiresAt = null;

    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < 32; i++) {
      buf.write('0123456789abcdef'[_random.nextInt(16)]);
    }
    _sessionToken = buf.toString();
    _sessionLabel = (label == null || label.trim().isEmpty)
        ? '手机'
        : label.trim().substring(0, label.trim().length.clamp(0, 24));
    _sessionExpiresAt = DateTime.now().add(sessionTtl);
    _seenCommandIds.clear();
    // ⚠️ 只记事件，不记配对码与凭证。
    Diagnostics.note('手机遥控', '已配对：$_sessionLabel');
    return _sessionToken;
  }

  /// 校验会话凭证。
  bool validate(String? token) {
    if (token == null || token.isEmpty) return false;
    if (!isPaired) return false;
    return _constantTimeEquals(token, _sessionToken!);
  }

  /// 解除配对（电视端主动解除 / 退出登录 / 关闭服务）。
  void revoke({String reason = '主动解除'}) {
    if (_sessionToken == null) return;
    _sessionToken = null;
    _sessionLabel = null;
    _sessionExpiresAt = null;
    Log.i('REMOTE 已解除配对：$reason');
    Diagnostics.note('手机遥控', '已解除配对（$reason）');
  }

  /// 命令去重：同一 id 第二次到达直接判定为「已处理」。
  ///
  /// 需求 §七.5「网络重试不能导致重复切歌或重复添加」——
  /// 手机在弱网下会重发，没有这道闸门就会连切两首。
  bool markCommand(String? id) {
    if (id == null || id.isEmpty) return true;
    if (_seenCommandIds.contains(id)) return false;
    _seenCommandIds.add(id);
    if (_seenCommandIds.length > _maxSeenCommands) {
      _seenCommandIds.removeRange(0, _seenCommandIds.length - _maxSeenCommands);
    }
    return true;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// 电视端本地遥控服务：HTTP（配对/状态/命令）+ WebSocket（实时同步）。
///
/// ## 为什么复用 `PlaybackControl` 而不是自己开一套
/// 需求 §七.3 明确要求「复用现有 PlaybackRepository/播放控制入口，
/// 避免建立另一套播放队列或第二个播放器」。
/// 本类**不持有任何播放状态**，只是把 HTTP/WS 消息翻译成
/// [PlaybackControl] 上的方法调用；状态一律从 [PlaybackControl.states] 读。
/// 因此电视遥控器、电视界面按钮、手机，三者看到的永远是同一份队列。
///
/// ## 声音不出电视
/// 手机上**不播放音频**，也不接收音频流地址 —— 只接收元数据与封面
/// （封面经电视代理，见 `/api/cover`），音频仍由电视自己的播放器输出。
/// 这也意味着手机拿不到任何 NAS 凭据（需求 §七.9）。
///
/// ## 网络边界
/// - 只绑定 `0.0.0.0`（局域网内可达）并**不**申请公网端口映射；
/// - 不做 UPnP / 端口转发；手机与电视必须在同一局域网；
/// - 所有 `/api/*`（除 `/` 与 `/api/pair`）都要求会话凭证。
class RemoteControlServer {
  RemoteControlServer({
    required PlaybackControl playback,
    required MusicRepository music,
    required LibraryRepository library,
    required LocalLibraryRepository local,
    RemotePairingManager? pairing,
  })  : _playback = playback,
        _music = music,
        _library = library,
        _local = local,
        pairing = pairing ?? RemotePairingManager();

  final PlaybackControl _playback;
  final MusicRepository _music;
  final LibraryRepository _library;
  final LocalLibraryRepository _local;

  final RemotePairingManager pairing;

  HttpServer? _server;
  StreamSubscription<void>? _stateSub;
  final Set<WebSocket> _sockets = <WebSocket>{};
  Timer? _pushTimer;
  bool _dirty = false;

  /// 默认端口。选 5667 附近的高位端口，避免与 NAS 的 5666/5667 冲突。
  static const int defaultPort = 18080;

  bool get isRunning => _server != null;

  int? get port => _server?.port;

  /// 已连接的手机数量。
  int get clientCount => _sockets.length;

  /// 本机在局域网里的 IPv4 地址（电视的主网卡地址）。
  ///
  /// ⚠️ 有多张网卡（有线 + 无线 + 虚拟网卡）时取**第一个非回环 IPv4**。
  /// 电视网线接路由器、手机走 Wi-Fi 时要能互通，因此不能用回环地址。
  static Future<String?> localIpv4() async {
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface i in ifaces) {
        for (final InternetAddress a in i.addresses) {
          if (a.address.isNotEmpty) return a.address;
        }
      }
    } catch (e) {
      Log.w('REMOTE 读取本机地址失败：$e');
    }
    return null;
  }

  /// 启动服务。返回 null 表示启动失败（端口被占 / 权限问题）。
  Future<int?> start({int port = defaultPort}) async {
    if (_server != null) return _server!.port;
    try {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: false,
      );
      _server = server;
      _stateSub = _playback.states.listen((_) => _markDirty());
      // 状态推送节流：播放位置每秒变化多次，直推会打爆手机端的渲染。
      _pushTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
        if (_dirty) {
          _dirty = false;
          _broadcastState();
        }
      });
      unawaited(_serve(server));
      pairing.regenerateCode();
      Log.i('REMOTE 服务已启动，端口 ${server.port}');
      Diagnostics.note('手机遥控', '服务已启动，端口 ${server.port}');
      return server.port;
    } catch (e, st) {
      Log.e('REMOTE 服务启动失败（端口 $port）：$e', e, st);
      Diagnostics.event('遥控服务启动失败：$e');
      return null;
    }
  }

  Future<void> stop({String reason = '服务已关闭'}) async {
    _pushTimer?.cancel();
    _pushTimer = null;
    await _stateSub?.cancel();
    _stateSub = null;
    for (final WebSocket ws in _sockets.toList()) {
      try {
        await ws.close();
      } catch (_) {
        // 关闭失败无所谓：连接已经不可用
      }
    }
    _sockets.clear();
    final HttpServer? s = _server;
    _server = null;
    await s?.close(force: true);
    // App 关闭 / 关闭服务 → 旧会话立即失效（需求 §七.9）
    pairing.revoke(reason: reason);
    Diagnostics.note('手机遥控', '服务已关闭（$reason）');
  }

  // ── HTTP ─────────────────────────────────────────────────

  Future<void> _serve(HttpServer server) async {
    await for (final HttpRequest req in server) {
      try {
        await _handle(req);
      } catch (e, st) {
        Log.w('REMOTE 处理请求出错：$e');
        Log.w('$st');
        try {
          req.response.statusCode = 500;
          await req.response.close();
        } catch (_) {
          // 响应已关闭
        }
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final String path = req.uri.path;

    if (req.method == 'GET' && (path == '/' || path == '/index.html')) {
      await _html(req);
      return;
    }
    if (req.method == 'POST' && path == '/api/pair') {
      await _pair(req);
      return;
    }
    if (path == '/ws') {
      await _websocket(req);
      return;
    }
    if (!_authorized(req)) {
      await _json(req, <String, Object?>{'error': 'unauthorized'}, status: 401);
      return;
    }
    switch (path) {
      case '/api/state':
        await _json(req, _stateJson());
        return;
      case '/api/cmd':
        await _command(req);
        return;
      case '/api/cover':
        await _cover(req);
        return;
      default:
        await _json(req, <String, Object?>{'error': 'not_found'}, status: 404);
        return;
    }
  }

  /// 会话凭证可以放在 `x-remote-token` 头，也可以放查询串（WebSocket 用）。
  bool _authorized(HttpRequest req) {
    final String? header = req.headers.value('x-remote-token');
    final String? query = req.uri.queryParameters['token'];
    return pairing.validate(header ?? query);
  }

  String _tokenOf(HttpRequest req) =>
      req.headers.value('x-remote-token') ??
      req.uri.queryParameters['token'] ??
      '';

  Future<void> _html(HttpRequest req) async {
    final String? ip = await localIpv4();
    final Map<String, String> subs = <String, String>{
      '{{APP}}': kRemoteAppName,
      '{{HOST}}': ip ?? '电视地址',
      '{{PORT}}': '${port ?? defaultPort}',
    };
    String body = remotePageHtml;
    subs.forEach((String k, String v) => body = body.replaceAll(k, v));
    req.response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    // 本地页面：禁止被外部站点 frame，降低被钓鱼页面套壳的风险。
    req.response.headers.set('x-frame-options', 'SAMEORIGIN');
    req.response.headers.set('x-content-type-options', 'nosniff');
    req.response.write(body);
    await req.response.close();
  }

  Future<void> _pair(HttpRequest req) async {
    // 请求体上限：配对请求就是一个 6 位码，给 4KB 绰绰有余
    //（需求 §七.7「校验未授权请求、来源和请求大小」）。
    final String raw = await _readBody(req, limit: 4096);
    Map<String, Object?> body = <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) body = Map<String, Object?>.from(decoded);
    } catch (_) {
      await _json(req, <String, Object?>{'error': 'bad_json'}, status: 400);
      return;
    }
    final String code = '${body['code'] ?? ''}';
    final String label = '${body['label'] ?? ''}';
    final String? token = pairing.pair(code: code, label: label);
    if (token == null) {
      await _json(req, <String, Object?>{'error': 'invalid_code'},
          status: 403);
      return;
    }
    await _json(req, <String, Object?>{
      'token': token,
      'ttlSeconds': RemotePairingManager.sessionTtl.inSeconds,
    });
    _broadcastState();
  }

  Future<void> _command(HttpRequest req) async {
    final String raw = await _readBody(req, limit: 16384);
    Map<String, Object?> body = <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) body = Map<String, Object?>.from(decoded);
    } catch (_) {
      await _json(req, <String, Object?>{'error': 'bad_json'}, status: 400);
      return;
    }
    final Map<String, Object?> res = await _dispatch(
      '${body['cmd'] ?? ''}',
      body['args'] is Map
          ? Map<String, Object?>.from(body['args']! as Map)
          : <String, Object?>{},
      '${body['id'] ?? ''}',
    );
    await _json(req, res);
  }

  Future<void> _cover(HttpRequest req) async {
    final String? coverId = req.uri.queryParameters['id'];
    final int size = int.tryParse(req.uri.queryParameters['size'] ?? '') ?? 300;
    if (coverId == null || coverId.isEmpty) {
      await _json(req, <String, Object?>{'error': 'missing_id'}, status: 400);
      return;
    }
    // ⚠️ 封面必须由**电视代理**：手机没有 NAS 凭据，也不能给它。
    //    电视用自己的 Cookie 取图后原样转发字节。
    try {
      final HttpClient client = HttpClient();
      final Uri uri = Uri.parse(_music.buildCoverUrl(coverId, size: size));
      final HttpClientRequest r = await client.getUrl(uri);
      _music.authHeaders.forEach(r.headers.set);
      final HttpClientResponse resp = await r.close();
      req.response.statusCode = resp.statusCode;
      final ContentType? ct = resp.headers.contentType;
      if (ct != null) req.response.headers.contentType = ct;
      await resp.pipe(req.response);
      client.close();
    } catch (e) {
      Log.w('REMOTE 封面代理失败：$e');
      if (!req.response.headersSent) {
        req.response.statusCode = 502;
      }
      await req.response.close();
    }
  }

  // ── WebSocket ────────────────────────────────────────────

  Future<void> _websocket(HttpRequest req) async {
    if (!_authorized(req)) {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final WebSocket ws = await WebSocketTransformer.upgrade(req);
    _sockets.add(ws);
    Log.i('REMOTE 手机已连接（当前 ${_sockets.length} 个）');
    Diagnostics.note('手机遥控', '已连接 ${_sockets.length} 台手机设备');
    ws.add(jsonEncode(<String, Object?>{'type': 'state', 'data': _stateJson()}));

    ws.listen(
      (Object? data) async {
        try {
          final Object? decoded = jsonDecode('$data');
          if (decoded is! Map) return;
          final Map<String, Object?> msg = Map<String, Object?>.from(decoded);
          if (msg['type'] == 'ping') {
            ws.add(jsonEncode(<String, Object?>{'type': 'pong'}));
            return;
          }
          if (msg['type'] == 'cmd') {
            final Map<String, Object?> res = await _dispatch(
              '${msg['cmd'] ?? ''}',
              msg['args'] is Map
                  ? Map<String, Object?>.from(msg['args']! as Map)
                  : <String, Object?>{},
              '${msg['id'] ?? ''}',
            );
            ws.add(jsonEncode(<String, Object?>{
              'type': 'ack',
              'id': msg['id'],
              'ok': res['ok'],
              'error': res['error'],
            }));
            _broadcastState();
          }
        } catch (e) {
          Log.w('REMOTE WebSocket 消息处理失败：$e');
        }
      },
      onDone: () {
        _sockets.remove(ws);
        Log.i('REMOTE 手机已断开（剩余 ${_sockets.length} 个）');
        Diagnostics.note('手机遥控',
            _sockets.isEmpty ? '已配对但当前无连接' : '已连接 ${_sockets.length} 台设备');
      },
      onError: (Object e) {
        _sockets.remove(ws);
        Log.w('REMOTE WebSocket 错误：$e');
      },
    );
  }

  // ── 命令分发 ──────────────────────────────────────────────

  Future<Map<String, Object?>> _dispatch(
    String cmd,
    Map<String, Object?> args,
    String id,
  ) async {
    // 去重：网络重试不会导致重复切歌 / 重复添加（需求 §七.5）
    if (!pairing.markCommand(id)) {
      return <String, Object?>{'ok': true, 'duplicate': true};
    }
    try {
      switch (cmd) {
        case 'play':
          await _playback.play();
        case 'pause':
          await _playback.pause();
        case 'toggle':
          await _playback.togglePlay();
        case 'next':
          await _playback.next();
        case 'previous':
          await _playback.previous();
        case 'seek':
          await _playback.seek(
            Duration(milliseconds: _asInt(args['positionMs'])),
          );
        case 'mode':
          await _playback.setMode(_parseMode('${args['value'] ?? ''}'));
        case 'select':
          await _select(_asInt(args['index']));
        case 'playGuid':
          await _playGuid('${args['guid'] ?? ''}');
        case 'favorite':
          await _local.toggleFavorite('${args['guid'] ?? ''}');
        case 'queue':
          return <String, Object?>{
            'ok': true,
            'items': _queueJson(
              _asInt(args['offset']),
              _asInt(args['limit'], fallback: 60),
            ),
          };
        case 'browse':
          return <String, Object?>{
            'ok': true,
            'items': _browseJson(
              _asInt(args['offset']),
              _asInt(args['limit'], fallback: 60),
            ),
          };
        case 'search':
          return <String, Object?>{
            'ok': true,
            'items': _searchJson('${args['q'] ?? ''}'),
          };
        default:
          return <String, Object?>{'ok': false, 'error': 'unknown_cmd'};
      }
      return <String, Object?>{'ok': true};
    } catch (e) {
      Log.w('REMOTE 命令 $cmd 执行失败：$e');
      return <String, Object?>{'ok': false, 'error': '$e'};
    }
  }

  Future<void> _select(int index) async {
    final PlaybackSnapshot snap = _playback.state;
    if (index < 0 || index >= snap.queue.length) return;
    // 复用同一个队列入口：重新建队列并定位到该下标。
    await _playback.playQueue(
      snap.queue,
      source: snap.source,
      startIndex: index,
    );
  }

  Future<void> _playGuid(String guid) async {
    if (guid.isEmpty) return;
    final List<Track> queue = _playback.state.queue;
    final int inQueue = queue.indexWhere((Track t) => t.guid == guid);
    if (inQueue >= 0) {
      await _select(inQueue);
      return;
    }
    // 不在当前队列 → 从曲库定位并用**曲库**建队列（与电视端点歌一致）
    final List<Track> lib = _library.tracks;
    final int idx = lib.indexWhere((Track t) => t.guid == guid);
    if (idx < 0) return;
    await _playback.playQueue(lib, source: QueueSource.library, startIndex: idx);
  }

  static PlayMode _parseMode(String raw) {
    for (final PlayMode m in PlayMode.values) {
      if (m.storageKey == raw || m.name == raw) return m;
    }
    return PlayMode.sequence;
  }

  static int _asInt(Object? v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  // ── 状态与列表的 JSON ─────────────────────────────────────

  void _markDirty() => _dirty = true;

  void _broadcastState() {
    if (_sockets.isEmpty) return;
    final String payload =
        jsonEncode(<String, Object?>{'type': 'state', 'data': _stateJson()});
    for (final WebSocket ws in _sockets.toList()) {
      try {
        ws.add(payload);
      } catch (_) {
        _sockets.remove(ws);
      }
    }
  }

  Map<String, Object?> _stateJson() {
    final PlaybackSnapshot s = _playback.state;
    final Track? t = s.currentSong;
    return <String, Object?>{
      'paired': true,
      'deviceLabel': pairing.sessionLabel,
      'isPlaying': s.isPlaying,
      'mode': s.mode.storageKey,
      'modeLabel': s.mode.label,
      'positionMs': s.position.inMilliseconds,
      'durationMs': s.duration.inMilliseconds,
      'index': s.currentIndex,
      'queueLength': s.queue.length,
      'sourceLabel': s.sourceLabel,
      'hasPrevious': s.hasPrevious,
      'error': s.error,
      'current': t == null
          ? null
          : <String, Object?>{
              'guid': t.guid,
              'title': t.title,
              'artist': t.artistNames,
              'album': t.album.name,
              'coverId': t.effectiveCoverId,
              'durationMs': t.durationMs,
              'favorite': _local.isFavorite(t.guid),
              'spec': t.audioSpec.display,
            },
    };
  }

  List<Map<String, Object?>> _queueJson(int offset, int limit) {
    final List<Track> q = _playback.state.queue;
    final int start = offset.clamp(0, q.length);
    final int end = (start + limit.clamp(1, 200)).clamp(0, q.length);
    return <Map<String, Object?>>[
      for (int i = start; i < end; i++)
        <String, Object?>{
          'index': i,
          'guid': q[i].guid,
          'title': q[i].title,
          'artist': q[i].artistNames,
          'album': q[i].album.name,
          'coverId': q[i].effectiveCoverId,
          'durationMs': q[i].durationMs,
        },
    ];
  }

  List<Map<String, Object?>> _browseJson(int offset, int limit) {
    final List<Track> all = _library.tracks;
    final int start = offset.clamp(0, all.length);
    final int end = (start + limit.clamp(1, 200)).clamp(0, all.length);
    return <Map<String, Object?>>[
      for (int i = start; i < end; i++)
        <String, Object?>{
          'guid': all[i].guid,
          'title': all[i].title,
          'artist': all[i].artistNames,
          'album': all[i].album.name,
          'coverId': all[i].effectiveCoverId,
          'durationMs': all[i].durationMs,
        },
    ];
  }

  List<Map<String, Object?>> _searchJson(String q) {
    if (q.trim().isEmpty) return <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Track t in _library.search(q).take(80))
        <String, Object?>{
          'guid': t.guid,
          'title': t.title,
          'artist': t.artistNames,
          'album': t.album.name,
          'coverId': t.effectiveCoverId,
          'durationMs': t.durationMs,
        },
    ];
  }

  // ── 工具 ─────────────────────────────────────────────────

  static Future<String> _readBody(HttpRequest req, {required int limit}) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > limit) break; // 超限即截断，避免恶意大包
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> _json(
    HttpRequest req,
    Map<String, Object?> data, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }
}

/// 二维码内容：**只有地址与配对码**，绝不含 NAS 账号/密码/长期令牌
/// （需求 §七.1）。
///
/// 路由用 `/#CODE`（fragment）。fragment 不会出现在 HTTP 请求里，
/// 因此它不会进任何服务端访问日志 —— 配对码本来就只该用一次，
/// 但少一处泄露面总是更好。
String remotePairingUrl({
  required String host,
  required int port,
  required String code,
}) =>
    'http://$host:$port/#$code';

/// 生成二维码（固定版本 4-L）。超长返回 null → 页面走「手输地址」兜底。
QrCode? remotePairingQr({required String host, required int port, required String code}) =>
    QrCode.encode(remotePairingUrl(host: host, port: port, code: code));

/// 手机网页里显示的应用名（与电视端共用同一个品牌常量，避免两处漂移）。
const String kRemoteAppName = kAppName;

/// 供 UI 展示的说明文本。
const String remoteHelpText =
    '手机与电视连同一个路由器/局域网，用相机或微信扫这个二维码，'
    '在打开的网页里输入配对码即可遥控。声音仍然由电视播放。';
