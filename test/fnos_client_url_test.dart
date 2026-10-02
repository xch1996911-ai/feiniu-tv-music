import 'package:feiniu_tv_music/servers/fnos/fnos_client.dart';
import 'package:feiniu_tv_music/servers/fnos/fnos_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

/// URL 构造测试（纯字符串，无需联网）。
void main() {
  test('buildStreamUrl 使用 guid 参数（实测支持 Range 206）', () {
    final c = FnosClient(baseUrl: 'http://192.168.1.10:5666');
    expect(
      c.buildStreamUrl('abc'),
      'http://192.168.1.10:5666/music/api/v1/track/stream?guid=abc',
    );
  });

  test('buildCoverUrl 使用 coverId 完整值（含前缀）', () {
    final c = FnosClient(baseUrl: 'http://192.168.1.10:5666');
    final url = c.buildCoverUrl('album_659bfc696e7045bb85f07eb45022c0f2');
    expect(url, contains('${FnosEndpoints.staticCover}?coverId=album_659bfc696e7045bb85f07eb45022c0f2'));
    // 默认尺寸取官方前端枚举中最大的已确认值
    expect(url, contains('size=${FnosClient.defaultCoverSize}'));
  });

  test('buildCoverUrl 支持自定义 size，size<=0 时不带该参数', () {
    final c = FnosClient(baseUrl: 'http://192.168.1.10:5666');
    expect(c.buildCoverUrl('cov', size: 400), contains('size=400'));
    expect(c.buildCoverUrl('cov', size: 0), isNot(contains('size=')));
  });

  test('coverId 前缀不被拆分，特殊字符被转义', () {
    final c = FnosClient(baseUrl: 'http://192.168.1.10:5666');
    for (final prefix in <String>['album', 'artist', 'track']) {
      expect(c.buildCoverUrl('${prefix}_1'), contains('coverId=${prefix}_1'));
    }
    expect(c.buildCoverUrl('a b'), contains('coverId=a+b'));
  });

  /// 真实故障回归（2026-10-03，海信 E7N Pro）：
  /// 用户在遥控器上把地址输成 `192.168.3.250:5666`（漏 `http://`），
  /// 请求没有 scheme → 界面永远停在「连接中」，且不给任何有效错误。
  group('normalizeBaseUrl（用户漏写 scheme 必须被兜住）', () {
    test('纯 host:port 自动补 http://', () {
      expect(FnosClient.normalizeBaseUrl('192.168.3.250:5666'),
          'http://192.168.3.250:5666');
      expect(FnosClient.normalizeBaseUrl('nas.local:5666'),
          'http://nas.local:5666');
    });

    test('已带 scheme 的不改写', () {
      expect(FnosClient.normalizeBaseUrl('http://192.168.1.10:5666'),
          'http://192.168.1.10:5666');
      expect(FnosClient.normalizeBaseUrl('https://nas.example.com:5667'),
          'https://nas.example.com:5667');
    });

    test('去掉尾斜杠（否则会拼出 //music/api/v1）', () {
      expect(FnosClient.normalizeBaseUrl('http://a.b:1/'), 'http://a.b:1');
      expect(FnosClient.normalizeBaseUrl('a.b:1///'), 'http://a.b:1');
    });

    test('IP 里的冒号不会被误判成 scheme', () {
      // 宽松规则（^[^/]+:// 之类）会把 `192.168.3.250:5666` 当成带 scheme 的串，
      // 这里断言「必须以字母开头的 scheme 判定」生效。
      final v = FnosClient.normalizeBaseUrl('192.168.3.250:5666');
      expect(v.startsWith('http://'), isTrue);
    });

    test('空串原样返回（由调用方决定如何提示）', () {
      expect(FnosClient.normalizeBaseUrl('   '), '');
    });

    test('构造时即归一化，URL 拼接结果正确', () {
      final c = FnosClient(baseUrl: '192.168.3.250:5666');
      expect(c.baseUrl, 'http://192.168.3.250:5666');
      expect(c.buildStreamUrl('abc'),
          'http://192.168.3.250:5666/music/api/v1/track/stream?guid=abc');
    });
  });
}
