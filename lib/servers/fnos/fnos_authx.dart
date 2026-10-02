import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 飞牛 Web 客户端的 `authx` 请求签名（兼容层）。
///
/// ## 定位（重要）
/// `authx` **不是**认证手段。真实 NAS 实测结论（`fnOS_API_真实契约.md` §1.1）：
/// - **Cookie `music-token=<token>` 才是硬门槛**，缺失即
///   `HTTP 401 {"code":99999,"msg":"INVALID TOKEN"}`；
/// - 官方 Web 客户端每个请求都带 `authx`，但该 NAS **未强校验**。
///
/// 因此本类只作为「与官方客户端行为一致的兼容层」：
/// 带上它不影响 Cookie 登录；将来若服务端收紧校验，也无需再改动调用方。
/// 任何情况下 **不得**因为签名失败而阻断 Cookie 认证流程。
///
/// ## 算法（逐行逆向自官方前端 bundle）
/// ```
/// SALT = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh'
/// GET  : payload = 查询串按 key 字典序规范化，'+' → '%20'
///        bodyHash = MD5(decodeURIComponent(payload))
/// 非GET: payload = data == null ? '' : JSON.stringify(data)
///        bodyHash = MD5(payload)
/// nonce     = 6 位数字，[100000, 999999]
/// timestamp = Date.now()，毫秒
/// sign      = MD5([SALT, pathname, nonce, timestamp, bodyHash, apiKey].join('_'))
/// authx     = 'nonce=<n>&timestamp=<t>&sign=<sign>'
/// ```
/// GET 分支里的 `decodeURIComponent` 前面还有一步
/// `s.replace(/%(?![0-9A-Fa-f]{2})/g, '%25')`，用于把残缺的百分号转义修好，
/// 避免 `decodeURIComponent` 抛 `URIError`（[getBodyHash] 已等价实现）。
class FnosAuthx {
  FnosAuthx._();

  /// 官方前端硬编码盐值（`fnOS_API_真实契约.md` §1.3）。
  static const String salt = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';

  /// 官方前端列出的免签名路径（前缀匹配）。
  static const List<String> signExemptPathPrefixes = <String>[
    '/client-login',
    '/app-auth-pick-file',
    '/init',
    '/login',
    '/oauth/result',
    '/welcome',
  ];

  static final Random _random = Random.secure();

  /// 匹配「残缺的百分号转义」：`%` 后面不是两位 hex。
  static final RegExp _lonePercent = RegExp(r'%(?![0-9A-Fa-f]{2})');

  /// 大写的 32 位 hex MD5 摘要（小写输出，与前端 SparkMD5 的 hex 输出一致）。
  static String md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

  /// 该路径是否属于官方免签名白名单。
  static bool isSignExempt(String pathname) =>
      signExemptPathPrefixes.any((p) => pathname.startsWith(p));

  /// application/x-www-form-urlencoded 序列化（等价于 `URLSearchParams.toString()` 的单元素行为）。
  ///
  /// 不做 100% 的字符集模仿会怎样：GUID / page / size 这类值是纯字母数字，
  /// 但歌词参数、搜索关键字可能含空格或中文，因此这里按规范逐字节实现，
  /// 而不是依赖 `Uri.encodeQueryComponent`（两者对 `!`/`'`/`(` 等字符的处理并不一致）。
  static String encodeComponent(String input) {
    final bytes = utf8.encode(input);
    final sb = StringBuffer();
    for (final b in bytes) {
      final isUnreserved = (b >= 0x41 && b <= 0x5A) || // A-Z
          (b >= 0x61 && b <= 0x7A) || // a-z
          (b >= 0x30 && b <= 0x39) || // 0-9
          b == 0x2A || // *
          b == 0x2D || // -
          b == 0x2E || // .
          b == 0x5F; // _
      if (isUnreserved) {
        sb.writeCharCode(b);
      } else if (b == 0x20) {
        sb.write('+');
      } else {
        sb.write('%');
        sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
    }
    return sb.toString();
  }

  /// 规范化 GET 查询串（对应前端 `yO`）：
  /// 丢弃 null，按 key 字典序排序，序列化后把 `+` 统一换成 `%20`。
  static String canonicalQuery(Map<String, dynamic> query) {
    final keys = query.keys.where((k) => query[k] != null).toList()..sort();
    final parts = <String>[];
    for (final k in keys) {
      parts.add('${encodeComponent(k)}=${encodeComponent(_jsString(query[k]))}');
    }
    return parts.join('&').replaceAll('+', '%20');
  }

  /// 拆出 pathname 与已解码的 query（对应前端 `bO`）。
  ///
  /// 传 `+`（查询串里的空格）会被还原为空格，与 `URLSearchParams` 行为一致；
  /// 值为字面量 `undefined` / `null` 的项被丢弃。
  static (String pathname, Map<String, dynamic> query) splitUrl(String url) {
    final uri = Uri.parse(url);
    final pathname = uri.path.isEmpty ? '/' : uri.path;
    final query = <String, dynamic>{};
    if (uri.hasQuery) {
      uri.queryParameters.forEach((k, v) {
        if (v != 'undefined' && v != 'null') query[k] = v;
      });
    }
    return (pathname, query);
  }

  /// 计算 bodyHash（对应前端 `xO` / `SO`）。
  static String getBodyHash(String payload, {required bool isGet}) {
    if (!isGet) return md5Hex(payload);
    final repaired = payload.replaceAll(_lonePercent, '%25');
    try {
      return md5Hex(Uri.decodeComponent(repaired));
    } on FormatException {
      // 与前端 catch 分支一致：解码失败时退回原始串的 MD5。
      return md5Hex(payload);
    }
  }

  /// 拼出待签名的原始串（六大段下划线连接）。
  static String signatureString({
    required String pathname,
    required String nonce,
    required String timestamp,
    required String bodyHash,
    String apiKey = '',
  }) =>
      <String>[salt, pathname, nonce, timestamp, bodyHash, apiKey].join('_');

  /// 生成 6 位 nonce，范围 `[100000, 999999]`（与前端 `Math.floor(Math.random()*9e5)+1e5` 一致）。
  static String generateNonce() => (100000 + _random.nextInt(900000)).toString();

  /// 构造 `authx` 请求头的值。
  ///
  /// [url] 可以是完整 URL 或 `path?query` 形式（相对 URL）。[data] 仅在非 GET 时参与签名。
  /// [nonce] / [timestamp] 允许注入，仅用于让单元测试可以对照官方算法的黄金向量。
  static String buildHeader({
    required String method,
    required String url,
    Object? data,
    String apiKey = '',
    String? nonce,
    String? timestamp,
  }) {
    final isGet = method.toUpperCase() == 'GET';
    final (pathname, query) = splitUrl(url);

    final String payload;
    if (isGet) {
      payload = canonicalQuery(query);
    } else if (data == null) {
      payload = '';
    } else {
      payload = jsonEncode(data);
    }

    final bodyHash = getBodyHash(payload, isGet: isGet);
    final n = nonce ?? generateNonce();
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch.toString();
    final sign = md5Hex(signatureString(
      pathname: pathname,
      nonce: n,
      timestamp: ts,
      bodyHash: bodyHash,
      apiKey: apiKey,
    ));

    return 'nonce=$n&timestamp=$ts&sign=$sign';
  }

  /// 近似 JS `String(v)`：整数型 double 不能渲染成 `1.0`。
  static String _jsString(Object? v) {
    if (v is double && v == v.roundToDouble() && v.isFinite) {
      return v.toInt().toString();
    }
    return '$v';
  }
}
