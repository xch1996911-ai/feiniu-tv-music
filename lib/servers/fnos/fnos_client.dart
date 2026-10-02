import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import '../../core/exceptions.dart';
import '../../core/log.dart';
import '../../core/result.dart';
import 'fnos_endpoints.dart';

/// 飞牛音乐底层 HTTP 客户端。
///
/// 职责边界（不在此层做领域模型映射，只返回原始 `data` Map）：
/// - 统一响应信封 `{code, msg, data}` 解析与错误归一化。
/// - Cookie 认证头 `music-token=<token>` 注入。
/// - `code == 120001` → [ErrorKind.tokenExpired]。
/// - 局域网自签 HTTPS 证书豁免**仅限** `trustedHosts` 中明确列出的主机/IP；
///   绝不对公网域名 / FN Connect / 普通 HTTPS 全局关闭 TLS 校验。
///
/// 说明：飞牛 app 端走 Cookie 方案（见 technical_research.md §2.2）。Web 端的
/// `authx` 签名头方案是否对 app 接口同样必需，需经 `tools/fnos_api_probe` 真机验证，
/// 验证结论写入 `docs/fnos_api_verified.md`。
class FnosClient {
  final String baseUrl; // 含 scheme + host + port，如 http://192.168.1.10:5666
  final List<String> trustedHosts;
  String? _token;
  late final Dio _dio;

  FnosClient({required this.baseUrl, this.trustedHosts = const []}) {
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
    ));
    _configureCertHandling();
  }

  void setToken(String? token) => _token = token;

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

  Map<String, String> get _headers {
    final h = <String, String>{};
    if (_token != null && _token!.isNotEmpty) {
      h['Cookie'] = 'music-token=$_token';
    }
    return h;
  }

  /// 流 / 封面请求所需的认证头（供播放引擎与图片加载携带，避免跨组件重复构造）。
  Map<String, String> get authHeaders => Map.from(_headers);

  Future<Result<Map<String, dynamic>>> getRaw(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final resp = await _dio.get(
        path,
        queryParameters: query,
        options: Options(headers: _headers),
      );
      return _unwrap(resp);
    } on DioException catch (e) {
      return Result.err(_toAppError(e));
    } catch (e, st) {
      return Result.err(AppError('未知请求错误', kind: ErrorKind.unknown, cause: e, stack: st));
    }
  }

  Future<Result<Map<String, dynamic>>> postRaw(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await _dio.post(
        path,
        data: body,
        options: Options(headers: _headers),
      );
      return _unwrap(resp);
    } on DioException catch (e) {
      return Result.err(_toAppError(e));
    } catch (e, st) {
      return Result.err(AppError('未知请求错误', kind: ErrorKind.unknown, cause: e, stack: st));
    }
  }

  Result<Map<String, dynamic>> _unwrap(Response resp) {
    final data = resp.data;
    if (data is! Map) {
      return const Result.err(AppError('响应不是合法 JSON 对象', kind: ErrorKind.parse));
    }
    final code = data['code'] as int? ?? -1;
    final msg = (data['msg'] as String?) ?? '';
    if (code == FnosEndpoints.codeTokenExpired) {
      return const Result.err(AppError('登录已失效，请重新登录', kind: ErrorKind.tokenExpired));
    }
    if (code != FnosEndpoints.codeOk) {
      return Result.err(AppError(
        msg.isNotEmpty ? msg : '服务端错误($code)',
        kind: ErrorKind.server,
      ));
    }
    final payload = data['data'];
    if (payload is! Map) {
      return const Result.err(AppError('响应 data 缺失', kind: ErrorKind.parse));
    }
    return Result.ok(payload as Map<String, dynamic>);
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
              kind: ErrorKind.server, cause: e);
        }
        return AppError('网络错误', kind: ErrorKind.network, cause: e);
    }
  }

  String buildStreamUrl(String trackGuid) =>
      '$baseUrl${FnosEndpoints.trackStream}?guid=$trackGuid';

  String buildCoverUrl(String coverId, {int size = 800}) =>
      '$baseUrl${FnosEndpoints.staticCover}?coverId=$coverId&size=$size';
}
