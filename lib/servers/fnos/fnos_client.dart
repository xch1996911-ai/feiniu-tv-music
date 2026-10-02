import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../core/exceptions.dart';
import '../../core/ids.dart';
import '../../core/log.dart';
import '../../core/result.dart';
import 'fnos_authx.dart';
import 'fnos_endpoints.dart';
import 'fnos_error_codes.dart';

/// 飞牛音乐底层 HTTP 客户端。
///
/// 职责边界（不在此层做领域模型映射，只返回原始 `data` Map）：
/// - 统一响应信封 `{code, msg, data}` 解析与错误归一化。
/// - **Cookie 认证**（硬门槛）：`Cookie: music-token=<token>`。
/// - **authx 签名**（兼容层）：与官方 Web 客户端行为对齐，但**与 Cookie 解耦**，
///   签名失败不影响 Cookie 登录，见 [FnosAuthx]。
/// - 局域网自签 HTTPS 证书豁免**仅限** `trustedHosts` 中明确列出的主机/IP；
///   绝不对公网域名 / FN Connect / 普通 HTTPS 全局关闭 TLS 校验。
///
/// 实测依据：`fnOS_API_真实契约.md` §1。
class FnosClient {
  /// 含 scheme + host + port，如 `http://192.168.1.10:5666`。
  ///
  /// 构造时一律经 [normalizeBaseUrl] 归一化 —— 用户漏写 `http://` 也能用，
  /// 不要指望遥控器输入会照抄 hint 里的写法。
  final String baseUrl;

  final List<String> trustedHosts;

  /// Web 端 apiKey 为空串（前端 `CO(request, apiKey)` 中 Web 传 `''`）。
  final String apiKey;

  String? _token;
  String? _deviceId;
  late final Dio _dio;

  /// 封面默认尺寸。
  ///
  /// 官方前端枚举值为 `200 / 120 / 60 / 100`，此处取**最大已确认值**作为默认，
  /// 避免传入服务端未验证的尺寸导致取图失败。
  static const int defaultCoverSize = 200;

  /// scheme 判定：必须以字母开头，后跟字母/数字/`+`/`-`/`.`，再跟 `://`。
  ///
  /// 刻意写成「字母开头」而不是更宽松的 `^[^/]+://`：`192.168.3.250:5666`
  /// 这类输入里也有冒号，宽松规则会把 IP 误判成 scheme。
  static final RegExp _schemeRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// 归一化 NAS 地址。
  ///
  /// 真实故障（2026-10-03，海信 E7N Pro 实机）：用户在电视上用遥控器输入
  /// `192.168.3.250:5666`（**漏掉 `http://`**）。地址栏 hint 里是带 scheme 的
  /// 完整写法，但遥控器输入不会照抄 hint。这个字符串若原样交给 Dio，
  /// 请求 URL 就没有 scheme，请求根本发不出去（或被判为相对地址），
  /// 界面表现是「一直显示连接中」，且不会给出任何有意义的错误。
  ///
  /// 所以容错必须做在这一层：所有入口（登录 / 恢复会话 / 探针）都经过它。
  static String normalizeBaseUrl(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return v;

    // 无 scheme → 默认补 http。局域网直连（HTTP 5666）是绝对主流；
    // HTTPS 5667 的场景用户一定会带上 `https://`（否则自签证书本就无法校验）。
    if (!_schemeRe.hasMatch(v)) {
      v = 'http://$v';
    }

    // 去掉尾部 `/`：端点路径自带前导 `/`，否则会拼出 `//music/api/v1/...`。
    final stripped = v.replaceFirst(RegExp(r'/+$'), '');
    // 输入形如 `http://` 时上面会把 scheme 也削掉；此时保留原值，
    // 让请求按原样失败（用户输入本身是错的，不该被悄悄改写）。
    return stripped.contains('://') ? stripped : v;
  }

  /// 允许注入 [adapter] 以便在无网络的单元测试里断言真实发出的请求
  /// （方法、路径、query、Cookie/authx 头、body）。
  FnosClient({
    required String baseUrl,
    this.trustedHosts = const [],
    String? deviceId,
    this.apiKey = '',
    HttpClientAdapter? adapter,
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        _deviceId = deviceId {
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
      // 非 2xx 不抛异常：飞牛的 401 响应体里带业务码 99999，
      // 必须让信封走到 _unwrap 才能被准确分类（而不是被压成「HTTP 401」）。
      validateStatus: (_) => true,
    ));
    if (adapter != null) {
      _dio.httpClientAdapter = adapter;
    } else {
      _configureCertHandling();
    }
  }

  void setToken(String? token) => _token = token;

  /// 设置 deviceId（登录前必须已就绪；由 [AuthRepository] 从安全存储读出后注入）。
  void setDeviceId(String? deviceId) => _deviceId = deviceId;

  /// 当前 deviceId；未设置时返回 null（不允许在此层隐式生成，否则会破坏「持久化复用」契约）。
  String? get deviceId => _deviceId;

  /// 已存储的认证 token（music-token）。
  String? get token => _token;

  void _configureCertHandling() {
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 仅用户明确信任的主机允许自签证书；其余严格校验。
        client.badCertificateCallback =
            (cert, host, port) => trustedHosts.contains(host);
        return client;
      },
    );
  }

  /// 流 / 封面 / 音频资源所需的认证头（Cookie 方案）。
  ///
  /// 这些资源是**直接 URL**（交给 ExoPlayer / Image 组件拉取），
  /// 因此只带 Cookie，不带 authx —— 与官方前端对静态资源的处理一致。
  Map<String, String> get authHeaders {
    final h = <String, String>{};
    if (_token != null && _token!.isNotEmpty) {
      h['Cookie'] = 'music-token=$_token';
    }
    return h;
  }

  /// API 请求头：Cookie（必需）+ authx（兼容层）。
  Map<String, String> _apiHeaders({
    required String method,
    required String url,
    Object? data,
  }) {
    final h = Map<String, String>.from(authHeaders);
    try {
      final pathname = Uri.parse(url).path;
      if (!FnosAuthx.isSignExempt(pathname)) {
        h['authx'] = FnosAuthx.buildHeader(
          method: method,
          url: url,
          data: data,
          apiKey: apiKey,
        );
      }
    } catch (e) {
      // 签名是兼容层，绝不能因为它失败而阻断 Cookie 认证流程。
      Log.w('authx 签名生成失败，已降级为纯 Cookie 请求：$e');
    }
    return h;
  }

  /// 把 path + query 拼成相对 URL。
  ///
  /// query 走 [FnosAuthx.canonicalQuery]（按 key 排序、`+`→`%20`），
  /// 使实际发出的查询串与签名时使用的规范化串**完全一致**，避免签名对不上。
  String _relativeUrl(String path, Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) return path;
    final q = FnosAuthx.canonicalQuery(query);
    return q.isEmpty ? path : '$path?$q';
  }

  Future<Result<Map<String, dynamic>>> getRaw(
    String path, {
    Map<String, dynamic>? query,
  }) =>
      _send(method: 'GET', path: path, query: query);

  Future<Result<Map<String, dynamic>>> postRaw(
    String path, [
    Map<String, dynamic>? body,
  ]) =>
      _send(method: 'POST', path: path, body: body ?? const <String, dynamic>{});

  Future<Result<Map<String, dynamic>>> _send({
    required String method,
    required String path,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
  }) async {
    final url = _relativeUrl(path, query);
    try {
      final resp = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: _apiHeaders(method: method, url: url, data: body),
        ),
      );
      return _unwrap(resp);
    } on DioException catch (e) {
      return Result.err(_toAppError(e));
    } catch (e, st) {
      return Result.err(
          AppError('未知请求错误', kind: ErrorKind.unknown, cause: e, stack: st));
    }
  }

  Result<Map<String, dynamic>> _unwrap(Response<dynamic> resp) {
    final status = resp.statusCode ?? 0;
    final data = resp.data;

    if (data is Map) {
      final code = data['code'] as int?;
      final msg = (data['msg'] as String?) ?? '';
      if (code != null) {
        if (code == FnosErrorCodes.ok) {
          final payload = data['data'];
          if (payload is Map) {
            return Result.ok(Map<String, dynamic>.from(payload));
          }
          // 少数接口成功时 data 为空/缺省（如登出），视为空对象而非解析失败。
          if (payload == null) return const Result.ok(<String, dynamic>{});
          return const Result.err(
              AppError('响应 data 结构异常', kind: ErrorKind.parse));
        }
        return Result.err(_businessError(code, msg, status));
      }
    }

    // 没有业务码可依据 → 退回 HTTP 状态兜底。
    final kind = FnosErrorCodes.kindForHttpStatus(status);
    if (kind == ErrorKind.tokenExpired) {
      return Result.err(AppError(
        FnosErrorCodes.messageOf(FnosErrorCodes.invalidToken),
        kind: ErrorKind.tokenExpired,
        cause: 'HTTP $status',
      ));
    }
    return Result.err(
        AppError('HTTP $status', kind: kind, cause: 'HTTP $status'));
  }

  AppError _businessError(int code, String serverMsg, int status) {
    final kind = FnosErrorCodes.kindOf(code);
    Log.w('飞牛业务错误 code=$code(${FnosErrorCodes.nameOf(code)}) '
        'http=$status msg=$serverMsg');
    final detail = 'code=$code ${FnosErrorCodes.nameOf(code)}'
        '${serverMsg.isEmpty ? '' : ' msg=$serverMsg'}'
        ' http=$status';
    return AppError(
      FnosErrorCodes.messageOf(code),
      kind: kind,
      cause: detail,
    );
  }

  AppError _toAppError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return AppError('网络不可达：${Log.redactHost(baseUrl)}',
            kind: ErrorKind.network, cause: e);
      default:
        if (e.response != null) {
          return AppError('HTTP ${e.response!.statusCode}',
              kind: FnosErrorCodes.kindForHttpStatus(
                  e.response!.statusCode ?? 0),
              cause: e);
        }
        return AppError('网络错误', kind: ErrorKind.network, cause: e);
    }
  }

  /// 音频流 URL。认证由请求头携带（见 [authHeaders]），不在 URL 暴露 token。
  ///
  /// 实测：该接口支持 **HTTP 206 Range**，因此 `just_audio` / ExoPlayer
  /// 可直接 Seek，无需自建分块下载。
  String buildStreamUrl(String trackGuid) =>
      '$baseUrl${FnosEndpoints.trackStream}?guid=${Uri.encodeQueryComponent(trackGuid)}';

  /// 封面 URL。
  ///
  /// ⚠️ [coverId] 必须传**完整值（含 `album_` / `artist_` / `track_` 前缀）**，
  /// 不允许拆掉前缀，否则服务端取不到封面。
  String buildCoverUrl(String coverId, {int size = defaultCoverSize}) {
    final parts = <String>[
      '${FnosEndpoints.paramCoverId}=${Uri.encodeQueryComponent(coverId)}',
    ];
    if (size > 0) parts.add('${FnosEndpoints.paramSize}=$size');
    return '$baseUrl${FnosEndpoints.staticCover}?${parts.join('&')}';
  }

  /// 校验 [coverId] 是否为带前缀的完整形态（仅用于断言/日志，不做改写）。
  static bool hasCoverPrefix(String coverId) =>
      coverId.contains('_') && coverId.length > 32;

  /// 设备 ID 形态校验（转发到 [Ids]，便于调用方不用直接依赖 core）。
  static bool isValidDeviceId(String? value) => Ids.isValidDeviceId(value);
}
