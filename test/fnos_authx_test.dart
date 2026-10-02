import 'package:feiniu_tv_music/servers/fnos/fnos_authx.dart';
import 'package:flutter_test/flutter_test.dart';

/// authx 签名器单元测试。
///
/// 黄金向量用独立实现（Python hashlib + urllib）按契约 §1.3 的伪代码算出，
/// 因此这些断言验证的是**算法本身**，而不是「实现和自己的实现一致」。
void main() {
  group('常量与工具', () {
    test('盐值与真实契约一致', () {
      expect(FnosAuthx.salt, 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh');
    });

    test('MD5 小写 hex（对照公开值）', () {
      expect(FnosAuthx.md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
      expect(FnosAuthx.md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('免签名白名单按前缀匹配（是前端自身路由，不是 /music/api/v1 下的接口）', () {
      for (final path in <String>[
        '/login',
        '/init',
        '/welcome',
        '/oauth/result',
        '/client-login',
        '/app-auth-pick-file',
      ]) {
        expect(FnosAuthx.isSignExempt(path), isTrue, reason: path);
      }
      // 业务接口一律需要签名：它们不以白名单前缀开头
      expect(FnosAuthx.isSignExempt('/music/api/v1/track/list'), isFalse);
      expect(
        FnosAuthx.isSignExempt('/music/api/v1/user/password-login'),
        isFalse,
      );
    });

    test('urlencoded 序列化：空格 → +，非 ASCII → 大写百分号转义', () {
      expect(FnosAuthx.encodeComponent('a b'), 'a+b');
      expect(FnosAuthx.encodeComponent('a_b-1.2*'), 'a_b-1.2*');
      expect(FnosAuthx.encodeComponent('中'), '%E4%B8%AD');
      expect(FnosAuthx.encodeComponent("it's"), 'it%27s');
    });
  });

  group('canonicalQuery（前端 yO）', () {
    test('按 key 字典序排序，并把 + 换成 %20', () {
      expect(
        FnosAuthx.canonicalQuery(<String, dynamic>{'b': '2', 'a': '1 2'}),
        'a=1%202&b=2',
      );
    });

    test('丢弃 null，保留 0 / false', () {
      expect(
        FnosAuthx.canonicalQuery(<String, dynamic>{
          'keep': 0,
          'flag': false,
          'drop': null,
        }),
        'flag=false&keep=0',
      );
    });

    test('整数型 double 不渲染成 1.0（对齐 JS String(v)）', () {
      expect(FnosAuthx.canonicalQuery(<String, dynamic>{'page': 1.0}), 'page=1');
    });
  });

  group('splitUrl（前端 bO）', () {
    test('拆出 pathname 与已解码 query，+ 还原为空格', () {
      final (path, query) = FnosAuthx.splitUrl('/music/api/v1/lyric/list?q=a+b');
      expect(path, '/music/api/v1/lyric/list');
      expect(query['q'], 'a b');
    });

    test('值为字面量 undefined / null 的项被丢弃', () {
      final (_, query) =
          FnosAuthx.splitUrl('/x?a=undefined&b=null&c=ok');
      expect(query.containsKey('a'), isFalse);
      expect(query.containsKey('b'), isFalse);
      expect(query['c'], 'ok');
    });
  });

  group('bodyHash', () {
    test('非 GET 直接对 payload 取 MD5', () {
      expect(
        FnosAuthx.getBodyHash('{"x":1}', isGet: false),
        FnosAuthx.md5Hex('{"x":1}'),
      );
    });

    test('GET 先 decodeURIComponent 再取 MD5', () {
      // 黄金向量：md5('q=a b')
      expect(
        FnosAuthx.getBodyHash('q=a%20b', isGet: true),
        'fae3d79d6ee9693a382f97de343846f9',
      );
    });

    test('GET 遇到残缺百分号转义不抛异常（对齐前端 try/catch）', () {
      expect(FnosAuthx.getBodyHash('q=100%', isGet: true), isNotEmpty);
    });
  });

  group('signatureString', () {
    test('六段下划线连接顺序：salt_pathname_nonce_timestamp_bodyHash_apiKey', () {
      expect(
        FnosAuthx.signatureString(
          pathname: '/p',
          nonce: '1',
          timestamp: '2',
          bodyHash: '3',
          apiKey: '',
        ),
        'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh_/p_1_2_3_',
      );
    });
  });

  group('buildHeader 黄金向量', () {
    test('GET：key 乱序也能规范化后再签名', () {
      final header = FnosAuthx.buildHeader(
        method: 'GET',
        url: '/music/api/v1/track/list?size=5&page=1',
        nonce: '123456',
        timestamp: '1700000000000',
      );
      expect(header, 'nonce=123456&timestamp=1700000000000&'
          'sign=796d8132689b0df0a818345d35dfc586');
    });

    test('POST：body 的 JSON 序列化后签名', () {
      final header = FnosAuthx.buildHeader(
        method: 'POST',
        url: '/music/api/v1/user/password-login',
        data: <String, dynamic>{
          'username': 'u',
          'password': 'p',
          'deviceId': 'd',
        },
        nonce: '654321',
        timestamp: '1700000000001',
      );
      expect(header, 'nonce=654321&timestamp=1700000000001&'
          'sign=15c2ba157089e0e5f1dd0a01164edf94');
    });

    test('GET：值带空格（%20）时先解码再签名', () {
      final header = FnosAuthx.buildHeader(
        method: 'GET',
        url: '/music/api/v1/lyric/list?q=a%20b',
        nonce: '111222',
        timestamp: '1700000000002',
      );
      expect(header, 'nonce=111222&timestamp=1700000000002&'
          'sign=849a23beef7515e0181c60f8bf476bc9');
    });

    test('POST 空体：bodyHash = md5("")', () {
      final header = FnosAuthx.buildHeader(
        method: 'POST',
        url: '/music/api/v1/user/logout',
        nonce: '000000',
        timestamp: '0',
      );
      // raw = salt_/music/api/v1/user/logout_000000_0_d41d8cd98f00b204e9800998ecf8427e_
      expect(
        header,
        contains('sign=${FnosAuthx.md5Hex(
          'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh_/music/api/v1/user/logout'
          '_000000_0_d41d8cd98f00b204e9800998ecf8427e_',
        )}'),
      );
    });

    test('走完整 URL 时同样只取 pathname 与 query 参与签名', () {
      final fromFull = FnosAuthx.buildHeader(
        method: 'GET',
        url: 'http://example.local:5666/music/api/v1/track/list?page=1&size=5',
        nonce: '123456',
        timestamp: '1700000000000',
      );
      expect(fromFull, contains('sign=796d8132689b0df0a818345d35dfc586'));
    });

    test('apiKey 参与签名（Web 端为空串）', () {
      final a = FnosAuthx.buildHeader(
        method: 'GET',
        url: '/x',
        nonce: '1',
        timestamp: '2',
        apiKey: '',
      );
      final b = FnosAuthx.buildHeader(
        method: 'GET',
        url: '/x',
        nonce: '1',
        timestamp: '2',
        apiKey: 'k',
      );
      expect(a, isNot(b));
    });
  });

  group('nonce', () {
    test('是 6 位数字且落在 [100000, 999999]', () {
      for (var i = 0; i < 200; i++) {
        final n = FnosAuthx.generateNonce();
        expect(n.length, 6);
        final v = int.parse(n);
        expect(v, greaterThanOrEqualTo(100000));
        expect(v, lessThanOrEqualTo(999999));
      }
    });
  });
}
