#!/usr/bin/env dart
///
/// 飞牛 fnOS 音乐 API 诊断工具（Phase 1）。
///
/// 用途：在真实飞牛 NAS 上验证当前版本 API 的真实行为，产出可写入
/// `docs/fnos_api_verified.md` 的事实证据。本工具**不依赖 App 代码**，独立运行。
///
/// 安全：
/// - 主机 / 用户名 / 密码 / Token 一律**不写入**命令行、shell history 与报告原文。
/// - 报告输出为 `probe_report_redacted.md`（另有时间戳归档副本写入 `.probe_results/`）。
/// - 报告自动脱敏：NAS IP、域名、FNID、用户名、密码、Token、Cookie、Authorization、
///   authx、GUID 与长十六进制串；查询参数值一律替换为 `<REDACTED>`。
/// - 报告刻意保留：HTTP 状态码、业务码 `code`、API 路径、响应耗时、JSON 字段名称、
///   duration 数值与单位线索、认证机制判定结论（排错与回填 docs 所需）。
/// - `--insecure` 仅对你**显式指定**的 NAS 主机放宽证书校验（局域网自签场景）；默认严格校验。
///
/// 用法（推荐：全部交互式输入，密码不回显）：
///   dart pub get
///   dart run bin/probe.dart
///   dart run bin/probe.dart --host https://nas.example.com:5667 --insecure
///
/// 编译为独立 EXE（目标机器无需 Flutter / Dart / Git / Node）：
///   dart pub get
///   dart analyze
///   dart compile exe bin/probe.dart -o fnos_api_probe.exe
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

const String kApiBase = '/music/api/v1';
const String kInitState = '$kApiBase/initialization/state';
const String kLogin = '$kApiBase/user/password-login';
const String kMe = '$kApiBase/user/me';
const String kTracks = '$kApiBase/track/list';
const String kAlbums = '$kApiBase/album/list';
const String kArtists = '$kApiBase/artist/list';
const String kLyric = '$kApiBase/lyric/list';
const String kStream = '$kApiBase/track/stream';
const String kCover = '$kApiBase/static/cover';

const int kCodeOk = 0;
const int kCodeTokenExpired = 120001;

class Entry {
  final String name;
  final String method;
  final String url;
  String status; // VERIFIED / FAILED / UNVERIFIED
  int? httpStatus;
  int? apiCode; // 业务码（信封 code 字段）
  int durationMs = 0;
  String note;
  Entry(this.name, this.method, this.url, this.status, this.note);
}

// ===================== 脱敏规则 =====================
// 目标：报告可安全分享，同时保留排错所需的 HTTP 状态 / 业务码 /
// API 路径 / 耗时 / JSON 字段名 / duration 单位 / 认证机制结论。

/// 用户名脱敏：不暴露任何字符，仅保留长度。
String redactUser(String u) => u.isEmpty ? '(empty)' : '<USERNAME len=${u.length}>';

/// Token 脱敏：不暴露任何字符（旧实现会泄露前 6 位，已移除）。
String redactToken(String t) => '<TOKEN len=${t.length}>';

/// 主机脱敏：仅保留 scheme 与端口，隐藏真实 IP / 域名。
String redactHost(String h) {
  final uri = Uri.tryParse(h);
  if (uri == null || uri.host.isEmpty) return '<NAS-HOST-REDACTED>';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://<NAS-HOST-REDACTED>$port';
}

final RegExp _reSecretKv = RegExp(
    r"(music[-_]?token|user[-_]?token|token|password|passwd|pwd|cookie|set-cookie|"
    r"authorization|authx|fnid|fn_id|username|user_name|account)"
    r"(\s*[:=]\s*)"
    r"""("[^"]*"|'[^']*'|[^,;&\s}\]]+)""",
    caseSensitive: false);
final RegExp _reIpv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
final RegExp _reIpv6 = RegExp(r'\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b');
final RegExp _reGuid = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');
final RegExp _reLongHex = RegExp(r'\b[0-9a-fA-F]{16,}\b');
final RegExp _reDomain = RegExp(
    r'\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+'
    r'(?:com|net|org|cn|io|local|lan|internal|home|xyz|top|me|cc|info)\b');

/// 对任意文本做兜底脱敏：密钥类键值对、IP、域名、FNID/GUID/长十六进制串。
///
/// 保留：HTTP 状态码、业务码、API 路径、耗时、JSON **字段名**、duration 数值。
String scrub(String input) {
  var s = input;
  s = s.replaceAllMapped(_reSecretKv, (m) => '${m.group(1)}${m.group(2)}<REDACTED>');
  s = s.replaceAll(_reGuid, '<ID-REDACTED>');
  s = s.replaceAll(_reIpv4, '<IP-REDACTED>');
  s = s.replaceAllMapped(_reIpv6, (_) => '<IPV6-REDACTED>');
  s = s.replaceAll(_reLongHex, '<HEX-REDACTED>');
  s = s.replaceAll(_reDomain, '<DOMAIN-REDACTED>');
  return s;
}

/// 从完整 URL 提取可安全展示的 API 路径：去掉主机，查询参数值一律脱敏。
///
/// 例：`http://192.168.1.10:5666/music/api/v1/track/stream?guid=abc`
///  →  `/music/api/v1/track/stream?guid=<REDACTED>`
String safePath(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return '<URL-REDACTED>';
  final buf = StringBuffer(uri.path);
  if (uri.queryParameters.isNotEmpty) {
    final parts = uri.queryParameters.keys.map((k) => '$k=<REDACTED>');
    buf.write('?${parts.join('&')}');
  }
  return buf.toString();
}

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('host', abbr: 'H', help: 'NAS 地址，含端口，如 http://192.168.1.10:5666')
    ..addOption('username', abbr: 'u')
    ..addOption('password', abbr: 'p')
    ..addOption('size', abbr: 's', defaultsTo: '10', help: '列表分页大小')
    ..addFlag('insecure', negatable: false, help: '放宽 TLS 校验（仅用于你自己的 NAS 自签证书）')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('参数错误: $e\n');
    print(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('飞牛 fnOS 音乐 API 诊断工具\n');
    print('用法:');
    print('  dart run bin/probe.dart [--host <url>] [--username <u>] [--password <p>] [--insecure]\n');
    print('未通过参数提供的项将交互式询问。密码输入不回显，');
    print('且不会出现在命令行、shell history 或日志中。\n');
    print(parser.usage);
    exit(0);
  }

  // ---- 交互式补全未提供的参数（密码不回显）----
  var hostArg = results['host'] as String?;
  if (hostArg == null || hostArg.trim().isEmpty) {
    stdout.write('NAS 地址（如 http://192.168.1.10:5666）: ');
    hostArg = _readLine();
  }
  final host = hostArg.trim().replaceAll(RegExp(r'/$'), '');
  if (host.isEmpty) {
    print('\n错误：NAS 地址不能为空。');
    exit(1);
  }

  var usernameArg = results['username'] as String?;
  if (usernameArg == null || usernameArg.trim().isEmpty) {
    stdout.write('用户名: ');
    usernameArg = _readLine();
  }
  final username = usernameArg.trim();

  String password;
  final passwordArg = results['password'] as String?;
  if (passwordArg == null || passwordArg.isEmpty) {
    password = _readPasswordNoEcho('密码: ');
    if (password.isEmpty) {
      print('\n错误：密码不能为空。');
      exit(1);
    }
  } else {
    print('');
    print('⚠️ 警告：密码经由 --password 命令行参数传入，可能残留在 shell history 与进程列表中。');
    print('   建议改为直接回车/省略该参数，使用交互式输入。');
    password = passwordArg;
  }
  final size = int.tryParse(results['size'] as String) ?? 10;
  final insecure = results['insecure'] as bool;

  final entries = <Entry>[];
  // duration 单位判定结果（仅数值与字段名，不含任何标识符）
  String? durationInfo;
  final client = HttpClient();
  if (insecure) {
    client.badCertificateCallback = (cert, h, port) => true;
    print('⚠️ 已启用 --insecure：仅对你显式指定的主机 ${redactHost(host)} 放宽 TLS 校验。\n');
  }

  try {
    // 1) 连接探测（无认证）
    await testInitState(client, host, entries);

    // 2) 登录
    final token = await testLogin(client, host, username, password, entries);
    if (token == null) {
      await finish(client, host, username, entries,
          token: null, durationInfo: durationInfo);
      return;
    }

    // 3) 认证机制判定：Cookie vs 头
    await testAuthMechanism(client, host, token, entries);

    // 4) user/me
    await testMe(client, host, token, entries);

    // 5) 曲目 / 专辑 / 歌手列表
    String? firstTrackGuid;
    await testList(client, host, token, kTracks, '曲目列表', size, entries,
        (data) {
      final list = data['list'];
      if (list is List && list.isNotEmpty) {
        final first = list.first;
        if (first is Map) {
          if (first['guid'] != null) firstTrackGuid = first['guid'] as String;
          // duration 单位判定：仅记录数值与类型，不泄露任何标识符。
          final d = first['duration'];
          if (d != null) {
            durationInfo = 'Track.duration 原始值=$d（JSON 类型 ${d.runtimeType}）。'
                '判定方法：若 3~5 分钟歌曲取值在 1.8e5~3e5 量级则为毫秒(ms)；'
                '若在 180~300 量级则为秒(s)。'
                'App 侧 Track.fromJson 目前按毫秒处理（durationMs），如为秒需修正。';
          }
          final spec = first['audioSpec'];
          if (spec is Map) {
            durationInfo = '${durationInfo ?? ''}'
                'audioSpec 字段名=${_keys(spec)}';
          }
        }
      }
    });
    await testList(client, host, token, kAlbums, '专辑列表', size, entries, (_) {});
    await testList(client, host, token, kArtists, '歌手列表', size, entries, (_) {});

    // 6) 歌词（需要曲目 guid）
    if (firstTrackGuid != null) {
      await testLyric(client, host, token, firstTrackGuid!, entries);
    }

    // 7) 流 URL 可访问性（Range 探测，不下载整曲）
    if (firstTrackGuid != null) {
      await testStream(client, host, token, firstTrackGuid!, entries);
    }

    await finish(client, host, username, entries,
        token: token, durationInfo: durationInfo);
  } catch (e, st) {
    print('诊断异常终止: $e\n$st');
    await finish(client, host, username, entries,
        token: null, durationInfo: durationInfo);
    exit(1);
  }
}

Future<void> testInitState(HttpClient client, String host, List<Entry> entries) async {
  final e = Entry('initialization/state', 'GET', '$host$kInitState', 'UNVERIFIED', '');
  final sw = Stopwatch()..start();
  try {
    final resp = await _getJson(client, '$host$kInitState');
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.httpStatus = resp.statusCode;
    e.apiCode = _codeOf(resp.json);
    if (resp.ok && resp.json is Map && resp.json['code'] != null) {
      e.status = 'VERIFIED';
      e.note = '返回 code=${resp.json['code']}，data 字段存在';
    } else {
      e.status = 'FAILED';
      e.note = '非预期响应: ${resp.summary}';
    }
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
  }
  entries.add(e);
}

Future<String?> testLogin(HttpClient client, String host, String username,
    String password, List<Entry> entries) async {
  final e = Entry('user/password-login', 'POST', '$host$kLogin', 'UNVERIFIED', '');
  final sw = Stopwatch()..start();
  final hash = _sha256Hex(password);
  try {
    final resp = await _postJson(client, '$host$kLogin', {
      'username': username,
      'password': hash,
    });
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.httpStatus = resp.statusCode;
    e.apiCode = _codeOf(resp.json);
    if (resp.ok && resp.json is Map) {
      final data = resp.json as Map;
      final code = data['code'];
      if (code == kCodeOk) {
        // 用 `is String` 做显式类型判定，替代多余的 as 强制转换（unnecessary_cast）。
        final token = data['data']?['userToken'] ?? data['data']?['token'];
        if (token is String && token.isNotEmpty) {
          e.status = 'VERIFIED';
          e.note = '登录成功，userToken 已下发（${redactToken(token)}）';
          entries.add(e);
          return token;
        }
        e.status = 'FAILED';
        e.note = '成功码但缺少可用 token 字段。data keys=${_keys(data['data'])}';
      } else {
        e.status = 'FAILED';
        e.note = '业务码=$code，msg=${data['msg']}';
      }
    } else {
      e.status = 'FAILED';
      e.note = '非预期响应: ${resp.summary}';
    }
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
  }
  entries.add(e);
  return null;
}

Future<void> testAuthMechanism(HttpClient client, String host, String token,
    List<Entry> entries) async {
  final e = Entry('认证机制判定 (Cookie vs 头)', 'GET', '$host$kMe', 'UNVERIFIED', '');
  final sw = Stopwatch()..start();

  // A: 仅 Cookie
  late _Resp cookieResp;
  late _Resp headerResp;
  try {
    cookieResp = await _getJson(client, '$host$kMe', headers: {'Cookie': 'music-token=$token'});
    // B: 无 Cookie，仅 X-Music-API 头（Web 端方案）
    headerResp = await _getJson(client, '$host$kMe', headers: {'X-Music-API': 'v1'});
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
    entries.add(e);
    return;
  }
  sw.stop();
  e.durationMs = sw.elapsedMilliseconds;
  e.httpStatus = cookieResp.statusCode;

  final cookieOk = cookieResp.ok && _codeOf(cookieResp.json) == kCodeOk;
  final headerOnlyOk = headerResp.ok && _codeOf(headerResp.json) == kCodeOk;

  if (cookieOk && !headerOnlyOk) {
    e.status = 'VERIFIED';
    e.note = 'Cookie(music-token) 单独即可认证；仅 X-Music-API 头（无 Cookie）失败 → 采用 Cookie 方案';
  } else if (cookieOk && headerOnlyOk) {
    e.status = 'UNVERIFIED';
    e.note = 'Cookie 与 X-Music-API 头都能认证（两套并存），需在 App 中同时携带';
  } else if (!cookieOk && headerOnlyOk) {
    e.status = 'UNVERIFIED';
    e.note = '仅 X-Music-API 头可认证，Cookie 无效 → 可能需要 authx 签名（需进一步抓包）';
  } else {
    e.status = 'FAILED';
    e.note = '两种方案均失败。Cookie 响应=${cookieResp.summary}；头响应=${headerResp.summary}';
  }
  entries.add(e);
}

Future<void> testMe(HttpClient client, String host, String token,
    List<Entry> entries) async {
  final e = Entry('user/me', 'GET', '$host$kMe', 'UNVERIFIED', '');
  final sw = Stopwatch()..start();
  try {
    final resp = await _getJson(client, '$host$kMe', headers: {'Cookie': 'music-token=$token'});
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.httpStatus = resp.statusCode;
    e.apiCode = _codeOf(resp.json);
    if (resp.ok && _codeOf(resp.json) == kCodeOk) {
      final data = resp.json['data'];
      e.status = 'VERIFIED';
      e.note = '用户信息 OK。user keys=${_keys(data)}';
    } else {
      e.status = 'FAILED';
      e.note = resp.summary;
    }
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
  }
  entries.add(e);
}

Future<void> testList(HttpClient client, String host, String token, String path,
    String label, int size, List<Entry> entries, void Function(Map) onData) async {
  final e = Entry(label, 'GET', '$host$path', 'UNVERIFIED', '');
  final sw = Stopwatch()..start();
  try {
    final resp = await _getJson(client, '$host$path',
        headers: {'Cookie': 'music-token=$token'},
        query: {'page': '1', 'size': '$size'});
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.httpStatus = resp.statusCode;
    e.apiCode = _codeOf(resp.json);
    if (resp.ok && _codeOf(resp.json) == kCodeOk) {
      final data = resp.json['data'];
      if (data is Map) {
        final list = data['list'];
        final total = data['total'];
        onData(data);
        e.status = 'VERIFIED';
        e.note = 'total=$total，本页返回 ${(list is List) ? list.length : 0} 条。list item keys=${_keys(list is List && list.isNotEmpty ? list.first : null)}';
      } else {
        e.status = 'FAILED';
        e.note = 'data 非对象: ${resp.summary}';
      }
    } else {
      e.status = 'FAILED';
      e.note = resp.summary;
    }
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
  }
  entries.add(e);
}

Future<void> testLyric(HttpClient client, String host, String token,
    String trackGuid, List<Entry> entries) async {
  final e = Entry('lyric/list', 'GET', '$host$kLyric', 'UNVERIFIED', '');
  final sw = Stopwatch()..start();
  try {
    final resp = await _getJson(client, '$host$kLyric',
        headers: {'Cookie': 'music-token=$token'}, query: {'guid': trackGuid});
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.httpStatus = resp.statusCode;
    e.apiCode = _codeOf(resp.json);
    if (resp.ok && _codeOf(resp.json) == kCodeOk) {
      final data = resp.json['data'];
      e.status = 'VERIFIED';
      e.note = '歌词接口可达。data keys=${_keys(data)}';
    } else {
      e.status = 'FAILED';
      e.note = resp.summary;
    }
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
  }
  entries.add(e);
}

Future<void> testStream(HttpClient client, String host, String token,
    String trackGuid, List<Entry> entries) async {
  final url = '$host$kStream?guid=$trackGuid';
  final e = Entry('track/stream (Range 探测)', 'GET', url, 'UNVERIFIED', '');
  final sw = Stopwatch()..start();
  try {
    final req = await client.openUrl('GET', Uri.parse(url));
    req.headers.set('Cookie', 'music-token=$token');
    req.headers.set('Range', 'bytes=0-0');
    final resp = await req.close();
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.httpStatus = resp.statusCode;
    // 音频流接口返回二进制音频，没有 {code,msg,data} JSON 信封，因此不记录业务码。
    // 注意：HttpClientResponse 是单订阅 Stream，响应体在下方 resp.drain() 中一次性消费，
    // 不可在此处再读一遍（也不应对音频做 jsonDecode）。
    final contentType = resp.headers.contentType?.mimeType;
    // 206 Partial / 200 OK 均视为流可访问
    if (resp.statusCode == 200 || resp.statusCode == 206) {
      e.status = 'VERIFIED';
      e.note = '流可访问。status=${resp.statusCode}，content-type=$contentType，支持 Range=${(resp.headers.value('accept-ranges') ?? resp.headers.value('Accept-Ranges') ?? '未知')}';
    } else {
      e.status = 'FAILED';
      e.note = '流返回非预期状态码 ${resp.statusCode}';
    }
    await resp.drain();
  } catch (err) {
    sw.stop();
    e.durationMs = sw.elapsedMilliseconds;
    e.status = 'FAILED';
    e.note = '请求异常: $err';
  }
  entries.add(e);
}

/// 转义 Markdown 表格单元格内容（避免 `|` 与换行破坏表格）。
String _mdEscape(String s) =>
    s.replaceAll('|', r'\|').replaceAll('\n', ' ').replaceAll('\r', ' ');

Future<void> finish(HttpClient client, String host, String username,
    List<Entry> entries,
    {required String? token, String? durationInfo}) async {
  client.close();

  // 认证机制结论：从判定条目中提取（这是 Phase 1 最关键的结论）
  final authEntry = entries.firstWhere(
    (e) => e.name.startsWith('认证机制判定'),
    orElse: () => Entry('认证机制判定', '-', '-', 'UNVERIFIED', '未执行判定'),
  );

  final buffer = StringBuffer();
  buffer.writeln('# 飞牛 fnOS 音乐 API 诊断报告（已脱敏）');
  buffer.writeln();
  buffer.writeln('- 生成时间: ${DateTime.now().toIso8601String()}');
  buffer.writeln('- 目标主机: ${redactHost(host)}');
  buffer.writeln('- 用户名: ${redactUser(username)}');
  buffer
      .writeln('- 登录状态: ${token != null ? '成功（${redactToken(token)}）' : '失败'}');
  buffer.writeln();

  buffer.writeln('## 1. 认证机制判定（Cookie vs authx 签名头）');
  buffer.writeln();
  buffer.writeln('- 结论: **${authEntry.status}**');
  buffer.writeln('- 说明: ${_mdEscape(scrub(authEntry.note))}');
  buffer.writeln('- App 影响: 若结论为「需要签名头 / 两者并存」，`FnosClient` 必须补充'
      '对应头或 authx 签名逻辑，否则无法登录。');
  buffer.writeln();

  buffer.writeln('## 2. duration 单位判定');
  buffer.writeln();
  buffer.writeln(durationInfo ?? '未取得 duration 样本（track/list 未返回条目或无 duration 字段）。');
  buffer.writeln();

  buffer.writeln('## 3. 接口验证结果');
  buffer.writeln();
  buffer
      .writeln('| 接口 | 方法 | API 路径 | HTTP | 业务码 | 耗时(ms) | 状态 | 备注（已脱敏） |');
  buffer.writeln('|---|---|---|---|---|---|---|---|');
  for (final e in entries) {
    buffer.writeln('| ${e.name} | ${e.method} | ${safePath(e.url)} | '
        '${e.httpStatus ?? '-'} | ${e.apiCode ?? '-'} | ${e.durationMs} | '
        '**${e.status}** | ${_mdEscape(scrub(e.note))} |');
  }
  buffer.writeln();

  buffer.writeln('## 4. 脱敏说明');
  buffer.writeln();
  buffer.writeln('已自动脱敏：NAS IP、域名、FNID、用户名、密码、Token、Cookie、');
  buffer.writeln('Authorization、authx、GUID 与长十六进制串（查询参数值一律 `<REDACTED>`）。');
  buffer.writeln();
  buffer.writeln('刻意保留：HTTP 状态码、业务码 `code`、API 路径、响应耗时、');
  buffer.writeln('JSON **字段名称**、duration 数值与单位线索、认证机制判定结论。');
  buffer.writeln();
  buffer.writeln('> 由 `tools/fnos_api_probe` 生成；'
      '可通过 `dart compile exe bin/probe.dart` 编译为独立 EXE 运行。');

  // ---- 控制台输出（同样脱敏）----
  print('\n========== 诊断结果 ==========');
  for (final e in entries) {
    print('[${e.status}] ${e.name} (${e.method}) http=${e.httpStatus ?? '-'} '
        'code=${e.apiCode ?? '-'} ${e.durationMs}ms');
    print('        ${scrub(e.note)}');
  }
  print('================================\n');
  print('认证机制判定: ${authEntry.status} —— ${scrub(authEntry.note)}');

  // ---- 落盘：主报告（当前目录）+ 带时间戳的归档副本 ----
  const mainName = 'probe_report_redacted.md';
  final mainFile = File(mainName);
  mainFile.writeAsStringSync(buffer.toString());
  print('报告已写入: ${mainFile.absolute.path}');

  final dir = Directory('.probe_results');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final archive = File(
      '.probe_results/probe_report_redacted_${DateTime.now().millisecondsSinceEpoch}.md');
  archive.writeAsStringSync(buffer.toString());
  print('归档副本: ${archive.absolute.path}\n');
}

String _sha256Hex(String input) {
  final digest = sha256.convert(utf8.encode(input));
  final b = StringBuffer();
  for (final byte in digest.bytes) {
    b.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

int? _codeOf(dynamic json) {
  if (json is Map && json['code'] is int) return json['code'] as int;
  return null;
}

String _keys(dynamic data) {
  if (data is Map) return (data.keys.toList()..sort()).join(',');
  if (data is List && data.isNotEmpty && data.first is Map) {
    return ((data.first as Map).keys.toList()..sort()).join(',');
  }
  return '(无/空)';
}

class _Resp {
  final int statusCode;
  final dynamic json;
  final bool ok;
  final String summary;
  _Resp({required this.statusCode, this.json, required this.ok, required this.summary});
}

Future<_Resp> _getJson(HttpClient client, String url,
    {Map<String, String>? headers, Map<String, String>? query}) async {
  return _request(client, 'GET', url, headers: headers, query: query);
}

Future<_Resp> _postJson(HttpClient client, String url, Map<String, dynamic> body) async {
  return _request(client, 'POST', url,
      headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
}

Future<_Resp> _request(HttpClient client, String method, String url,
    {Map<String, String>? headers, Map<String, String>? query, String? body}) async {
  var uri = Uri.parse(url);
  if (query != null) {
    uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }
  final req = await client.openUrl(method, uri);
  headers?.forEach((k, v) => req.headers.set(k, v));
  if (body != null) req.write(body);
  final resp = await req.close();
  final raw = await resp.transform(utf8.decoder).join();
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    decoded = null;
  }
  final ok = resp.statusCode >= 200 && resp.statusCode < 300;
  final summary = decoded is Map
      ? 'code=${decoded['code']}, msg=${decoded['msg']}'
      : 'status=${resp.statusCode}, body=${raw.length > 120 ? raw.substring(0, 120) : raw}';
  return _Resp(statusCode: resp.statusCode, json: decoded, ok: ok, summary: summary);
}

// ===================== 交互式安全输入 =====================

/// 读取一行普通输入（回显正常），去除首尾空白。
String _readLine() {
  final line = stdin.readLineSync();
  return (line ?? '').trim();
}

/// 读取密码：关闭终端回显，密码不经过命令行 / shell history / 日志。
///
/// 回显关闭通过 Win32 Console API（`ENABLE_ECHO_INPUT`）实现，不依赖任何外部进程，
/// 因此密码不会出现在任何子进程的命令行参数里。
String _readPasswordNoEcho(String prompt) {
  if (!Platform.isWindows) {
    // 非 Windows 回退：无回显开关时，至少不把密码写进任何日志或参数。
    stdout.write(prompt);
    return _readLine();
  }

  final originalMode = _disableWindowsConsoleEcho();
  if (originalMode == null) {
    stdout.write(prompt);
    stdout.writeln('');
    stdout.writeln('⚠️ 无法关闭终端回显，密码输入将可见，请注意遮挡屏幕。');
    return stdin.readLineSync() ?? '';
  }

  try {
    stdout.write(prompt);
    final line = stdin.readLineSync() ?? '';
    // 回显关闭后终端不会输出换行，这里补一个以保持输出整洁。
    stdout.writeln('');
    return line;
  } finally {
    _restoreWindowsConsoleEcho(originalMode);
  }
}

/// 关闭 STD_INPUT 的回显，返回原始 console mode（失败返回 null）。
int? _disableWindowsConsoleEcho() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');

    final getStdHandle = kernel32.lookupFunction<
        IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final getConsoleMode = kernel32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetConsoleMode');
    final setConsoleMode = kernel32.lookupFunction<
        Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetConsoleMode');

    // STD_INPUT_HANDLE 的 DWORD 取值（(DWORD)(-10)）。
    const stdInputHandle = 0xFFFFFFF6;
    // ENABLE_ECHO_INPUT
    const enableEchoInput = 0x0004;

    final handle = getStdHandle(stdInputHandle);
    if (handle == 0 || handle == -1) return null;

    final modePtr = calloc<Uint32>();
    try {
      if (getConsoleMode(handle, modePtr) == 0) return null;
      final original = modePtr.value;
      if (setConsoleMode(handle, original & ~enableEchoInput) == 0) return null;
      return original;
    } finally {
      calloc.free(modePtr);
    }
  } catch (_) {
    return null;
  }
}

/// 恢复终端回显到原始 console mode。
void _restoreWindowsConsoleEcho(int originalMode) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getStdHandle = kernel32.lookupFunction<
        IntPtr Function(Uint32),
        int Function(int)>('GetStdHandle');
    final setConsoleMode = kernel32.lookupFunction<
        Int32 Function(IntPtr, Uint32),
        int Function(int, int)>('SetConsoleMode');
    const stdInputHandle = 0xFFFFFFF6;
    setConsoleMode(getStdHandle(stdInputHandle), originalMode);
  } catch (_) {
    // 恢复失败不应遮蔽主流程异常。
  }
}
