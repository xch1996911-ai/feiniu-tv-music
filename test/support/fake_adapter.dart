import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 一次被拦截到的请求，用于断言「客户端实际发了什么」。
class RecordedRequest {
  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final Object? data;

  RecordedRequest(this.method, this.uri, this.headers, this.data);

  String get path => uri.path;
  Map<String, String> get query => uri.queryParameters;

  /// 请求体（Dio 可能已把 Map 序列化成 JSON 字符串）。
  Object? get body {
    final d = data;
    if (d is String && d.isNotEmpty) {
      try {
        return jsonDecode(d);
      } catch (_) {
        return d;
      }
    }
    return d;
  }
}

class _Route {
  final int status;
  final Object body;
  const _Route(this.status, this.body);
}

/// 离线 Dio 适配器：拦截所有请求并返回预置响应，同时记录请求内容。
///
/// 这样可以在**不联网、不接触真实 NAS** 的前提下断言：
/// Cookie 头、authx 头、query 参数名（page/size/trackGUID）、
/// 以及 99999 / 120001 等错误码的映射结果。
class FakeAdapter implements HttpClientAdapter {
  final List<RecordedRequest> requests = <RecordedRequest>[];
  final Map<String, _Route> _routes = <String, _Route>{};
  _Route? _fallback;

  /// 注册 `METHOD path` → 响应。
  void on(
    String method,
    String path, {
    required int status,
    required Object body,
  }) {
    _routes['${method.toUpperCase()} $path'] = _Route(status, body);
  }

  /// 未命中路由时的兜底响应。
  void fallback({required int status, required Object body}) {
    _fallback = _Route(status, body);
  }

  RecordedRequest get last => requests.last;

  bool get isEmpty => requests.isEmpty;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(RecordedRequest(
      options.method,
      options.uri,
      Map<String, dynamic>.from(options.headers),
      options.data,
    ));

    final route = _routes['${options.method.toUpperCase()} ${options.uri.path}'] ??
        _fallback;
    if (route == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 100005, 'msg': 'NotFound'}),
        404,
        headers: _jsonHeaders,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(route.body),
      route.status,
      headers: _jsonHeaders,
    );
  }

  @override
  void close({bool force = false}) {}

  static const Map<String, List<String>> _jsonHeaders = <String, List<String>>{
    'content-type': <String>['application/json; charset=utf-8'],
  };
}
