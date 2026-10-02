import 'package:feiniu_tv_music/servers/fnos/fnos_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildStreamUrl / buildCoverUrl 纯字符串构造（无需联网）', () {
    final c = FnosClient(baseUrl: 'http://192.168.1.10:5666');
    expect(
      c.buildStreamUrl('abc'),
      'http://192.168.1.10:5666/music/api/v1/track/stream?guid=abc',
    );
    expect(c.buildCoverUrl('cov'), contains('coverId=cov'));
    expect(c.buildCoverUrl('cov'), contains('size=800'));
    expect(c.buildCoverUrl('cov', size: 400), contains('size=400'));
  });
}
