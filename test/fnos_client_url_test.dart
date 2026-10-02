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
}
