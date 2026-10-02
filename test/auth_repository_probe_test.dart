import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/servers/fnos/fnos_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

/// `AuthRepository.probe` —— 免登录连通性探测。
///
/// 这条测试盯住一个**真实故障**：用户在电视遥控器上把 NAS 地址输成
/// `192.168.3.250:5666`（漏掉 `http://`），请求 URL 因此没有 scheme，
/// 界面上表现为「登录一直显示连接中」，且没有任何有效错误。
/// 归一化必须做在客户端层，所有入口（登录 / 恢复会话 / 探测）都经过它。
void main() {
  FakeAdapter okAdapter() => FakeAdapter()
    ..on(
      'GET',
      FnosEndpoints.initializationState,
      status: 200,
      body: <String, dynamic>{'code': 0, 'data': <String, dynamic>{}},
    );

  group('AuthRepository.probe', () {
    test('漏写 http:// 时仍发出带 scheme 的绝对 URL（回归）', () async {
      final fake = okAdapter();
      final repo = AuthRepository();

      final res = await repo.probe('192.168.3.250:5666', adapter: fake);

      expect(res.isOk, isTrue, reason: res.isErr ? res.error.message : '');
      expect(res.value, contains('连通正常'));
      final uri = fake.last.uri;
      expect(uri.scheme, 'http');
      expect(uri.host, '192.168.3.250');
      expect(uri.port, 5666);
      expect(uri.path, FnosEndpoints.initializationState);
    });

    test('已带 scheme 的地址不被二次改写；尾斜杠被去掉', () async {
      final fake = okAdapter();
      final repo = AuthRepository();

      await repo.probe('https://nas.example.com:5667/', adapter: fake);

      final uri = fake.last.uri;
      expect(uri.scheme, 'https');
      expect(uri.host, 'nas.example.com');
      expect(uri.port, 5667);
      // 尾斜杠没去掉的话这里会变成 `//music/...`
      expect(uri.path, FnosEndpoints.initializationState);
    });

    test('探测失败时返回 Result.err 而不是抛异常（界面才有东西可显示）', () async {
      final fake = FakeAdapter()
        ..fallback(
          status: 404,
          body: <String, dynamic>{'code': 100005, 'msg': 'Not Found'},
        );
      final repo = AuthRepository();

      final res = await repo.probe('192.168.3.250:5666', adapter: fake);

      expect(res.isErr, isTrue);
      expect(res.error.message, isNotEmpty);
    });

    test('normalizeHost 委托给同一套规则（供界面显示实际请求地址）', () {
      final repo = AuthRepository();
      expect(repo.normalizeHost('192.168.3.250:5666'),
          'http://192.168.3.250:5666');
      expect(repo.normalizeHost('http://a.b:1/'), 'http://a.b:1');
    });
  });
}
