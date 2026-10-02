import 'package:feiniu_tv_music/core/exceptions.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/servers/fnos/fnos_client.dart';
import 'package:feiniu_tv_music/servers/fnos/fnos_endpoints.dart';
import 'package:feiniu_tv_music/servers/fnos/fnos_error_codes.dart';
import 'package:feiniu_tv_music/servers/fnos/fnos_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fnos_samples.dart';
import 'support/fake_adapter.dart';

const String _base = 'http://example.local:5666';

FnosClient _client(FakeAdapter adapter, {String? token}) {
  final c = FnosClient(baseUrl: _base, adapter: adapter);
  if (token != null) c.setToken(token);
  return c;
}

FnosProvider _provider(FakeAdapter adapter) =>
    FnosProvider(baseUrl: _base, deviceId: testDeviceId, adapter: adapter);

void main() {
  group('Cookie 认证（硬门槛）', () {
    test('持有 token 时每个 API 请求都带 Cookie: music-token=<token>', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.userMe,
            status: 200, body: <String, dynamic>{'code': 0, 'data': <String, dynamic>{}});
      final c = _client(fake, token: 'TOKEN123');
      await c.getRaw(FnosEndpoints.userMe);

      expect(fake.last.headers['Cookie'], 'music-token=TOKEN123');
    });

    test('无 token 时不带 Cookie 头（由服务端返回 99999）', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.userMe,
            status: 401, body: invalidTokenResponse());
      final c = _client(fake);
      final res = await c.getRaw(FnosEndpoints.userMe);

      expect(fake.last.headers.containsKey('Cookie'), isFalse);
      expect(res.isErr, isTrue);
      expect(res.error.kind, ErrorKind.tokenExpired);
    });

    test('authHeaders（供播放器/图片组件用）只含 Cookie，不含 authx', () {
      final c = _client(FakeAdapter(), token: 'T');
      expect(c.authHeaders, <String, String>{'Cookie': 'music-token=T'});
      expect(c.authHeaders.containsKey('authx'), isFalse);
    });
  });

  group('authx 签名（兼容层，与 Cookie 解耦）', () {
    test('API 请求自动附带 authx 头，且形状为 nonce/timestamp/sign', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.trackList,
            status: 200, body: trackListResponse());
      final c = _client(fake, token: 'T');
      await c.getRaw(FnosEndpoints.trackList, query: <String, dynamic>{'page': 1, 'size': 5});

      final authx = fake.last.headers['authx'] as String?;
      expect(authx, isNotNull);
      expect(authx, matches(RegExp(r'^nonce=\d{6}&timestamp=\d{13}&sign=[0-9a-f]{32}$')));
      // Cookie 与 authx 同时存在，互不影响
      expect(fake.last.headers['Cookie'], 'music-token=T');
    });

    test('查询值含空格与中文时，authx 与 Cookie 均正常', () async {
      final fake = FakeAdapter()
        ..fallback(status: 200, body: trackListResponse());
      final c = _client(fake, token: 'T');
      final res = await c.getRaw(FnosEndpoints.trackList,
          query: <String, dynamic>{'q': '中 文'});

      expect(fake.requests.length, 1);
      expect(fake.last.headers['Cookie'], 'music-token=T');
      expect(fake.last.headers['authx'], isNotNull);
      expect(fake.last.query['q'], '中 文');
      expect(res.isOk, isTrue);
    });
  });

  group('分页参数只能是 page + size', () {
    test('track/list 发出的 query 恰好是 page 与 size', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.trackList,
            status: 200, body: trackListResponse());
      final p = _provider(fake);
      await p.getTracks(2, 5);

      expect(fake.last.query, <String, String>{'page': '2', 'size': '5'});
      expect(fake.last.query.containsKey('pageSize'), isFalse);
      expect(fake.last.query.containsKey('limit'), isFalse);
      expect(fake.last.uri.query, 'page=2&size=5');
    });

    test('album/list 与 artist/list 同样使用 page + size', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.albumList,
            status: 200,
            body: <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'list': <dynamic>[], 'total': 0}
            })
        ..on('GET', FnosEndpoints.artistList,
            status: 200,
            body: <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'list': <dynamic>[], 'total': 0}
            });
      final p = _provider(fake);
      await p.getAlbums(1, 50);
      expect(fake.last.query, <String, String>{'page': '1', 'size': '50'});
      await p.getArtists(3, 20);
      expect(fake.last.query, <String, String>{'page': '3', 'size': '20'});
    });

    test('解析 list/total，并保留请求的 page/size', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.trackList,
            status: 200, body: trackListResponse(total: 137));
      final p = _provider(fake);
      final res = await p.getTracks(1, 50);

      expect(res.isOk, isTrue);
      expect(res.value.total, 137);
      expect(res.value.page, 1);
      expect(res.value.size, 50);
      expect(res.value.items.single, isA<Track>());
      expect(res.value.items.single.durationMs, 218711);
    });
  });

  group('歌词参数必须是 trackGUID', () {
    test('getLyrics 发出 trackGUID，而不是 guid', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.lyricList,
            status: 200, body: lyricListResponse());
      final p = _provider(fake);
      await p.getLyrics('190294f1459e486291cab74dfc8da470');

      expect(fake.last.query,
          <String, String>{'trackGUID': '190294f1459e486291cab74dfc8da470'});
      expect(fake.last.query.containsKey('guid'), isFalse);
    });

    test('服务端因参数错误返回 100002 时映射为服务端错误', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.lyricList,
            status: 200, body: invalidArgsResponse());
      final p = _provider(fake);
      final res = await p.getLyrics('g');

      expect(res.isErr, isTrue);
      expect(res.error.kind, ErrorKind.server);
      expect(res.error.message, contains('参数无效'));
    });
  });

  group('业务错误码映射', () {
    final errFor = (FnosClient client, String path) async {
      final res = await client.getRaw(path);
      expect(res.isErr, isTrue);
      return res.error;
    };

    test('HTTP 401 + 99999 → tokenExpired（Cookie 缺失/失效）', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.trackList,
            status: 401, body: invalidTokenResponse());
      final e = await errFor(_client(fake), FnosEndpoints.trackList);
      expect(e.kind, ErrorKind.tokenExpired);
      expect(e.message, contains('登录已失效'));
    });

    test('120001 → auth（登录/授权失败），与 99999 明确区分', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.userMe,
            status: 200, body: unauthorizedResponse());
      final e = await errFor(_client(fake), FnosEndpoints.userMe);
      expect(e.kind, ErrorKind.auth);
      expect(e.kind, isNot(ErrorKind.tokenExpired));
      expect(e.message, contains('登录失败'));
    });

    test('100001 → server（含参数缺失，如缺 deviceId）', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.userMe,
            status: 200, body: unknownErrorResponse());
      final e = await errFor(_client(fake), FnosEndpoints.userMe);
      expect(e.kind, ErrorKind.server);
      expect(e.kind, isNot(ErrorKind.auth));
    });

    test('100005 → notFound', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.albumDetail,
            status: 200,
            body: <String, dynamic>{'code': 100005, 'msg': 'NotFound'});
      final e = await errFor(_client(fake), FnosEndpoints.albumDetail);
      expect(e.kind, ErrorKind.notFound);
    });

    test('错误码常量与真实契约一致', () {
      expect(FnosErrorCodes.ok, 0);
      expect(FnosErrorCodes.unknown, 100001);
      expect(FnosErrorCodes.invalidArgs, 100002);
      expect(FnosErrorCodes.adminRequired, 100003);
      expect(FnosErrorCodes.forbidden, 100004);
      expect(FnosErrorCodes.notFound, 100005);
      expect(FnosErrorCodes.unauthorized, 120001);
      expect(FnosErrorCodes.userDisabled, 120002);
      expect(FnosErrorCodes.invalidToken, 99999);
    });

    test('没有业务码时按 HTTP 状态兜底：500 → server', () async {
      final fake = FakeAdapter()
        ..on('GET', FnosEndpoints.userMe,
            status: 500, body: <String, dynamic>{'oops': true});
      final e = await errFor(_client(fake), FnosEndpoints.userMe);
      expect(e.kind, ErrorKind.server);
    });
  });

  group('登录协议', () {
    test('提交 username / password(sha256) / deviceId(32hex)，token 取 data.userToken',
        () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200, body: loginResponseSample());
      final p = _provider(fake);
      final res = await p.login('  testuser  ', 'pwdhash');

      expect(res.isOk, isTrue);
      expect(res.value.token, testToken);
      expect(res.value.user.name, 'testuser');
      expect(res.value.user.isAdmin, isTrue);
      expect(res.value.user.createdAt!.toUtc().year, 2026);

      final body = fake.last.body! as Map<String, dynamic>;
      expect(fake.last.method, 'POST');
      expect(fake.last.path, '/music/api/v1/user/password-login');
      expect(body['username'], 'testuser'); // 已 trim
      expect(body['password'], 'pwdhash');
      final deviceId = body['deviceId'] as String;
      expect(deviceId.length, 32);
      expect(RegExp(r'^[a-f0-9]{32}$').hasMatch(deviceId), isTrue);
    });

    test('token 提取兼容 result.token（桌面桥接层形状），但 userToken 优先', () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200,
            body: <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'userToken': 'PRIMARY_TOKEN',
                'result': <String, dynamic>{'token': 'FALLBACK_TOKEN'},
                'user': <String, dynamic>{'guid': 'g', 'name': 'n'},
              },
            });
      final p = _provider(fake);
      final res = await p.login('u', 'h');
      expect(res.value.token, 'PRIMARY_TOKEN');
    });

    test('缺少 userToken 时回退 result.token', () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200,
            body: <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'result': <String, dynamic>{'token': 'FALLBACK_TOKEN'},
                'user': <String, dynamic>{'guid': 'g', 'name': 'n'},
              },
            });
      final p = _provider(fake);
      final res = await p.login('u', 'h');
      expect(res.value.token, 'FALLBACK_TOKEN');
    });

    test('缺少平铺 token 时回退 data.token', () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200,
            body: <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'token': 'FLAT_TOKEN',
                'user': <String, dynamic>{'guid': 'g', 'name': 'n'},
              },
            });
      final p = _provider(fake);
      final res = await p.login('u', 'h');
      expect(res.value.token, 'FLAT_TOKEN');
    });

    test('响应里完全没有 token → parse 错误', () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200,
            body: <String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'user': <String, dynamic>{'guid': 'g', 'name': 'n'},
              },
            });
      final p = _provider(fake);
      final res = await p.login('u', 'h');
      expect(res.isErr, isTrue);
      expect(res.error.kind, ErrorKind.parse);
    });

    test('凭据错误 120001 → auth', () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200, body: unauthorizedResponse());
      final p = _provider(fake);
      final res = await p.login('u', 'h');
      expect(res.isErr, isTrue);
      expect(res.error.kind, ErrorKind.auth);
    });

    test('未提供 deviceId 时兜底生成合法值（不发出非法请求）', () async {
      final fake = FakeAdapter()
        ..on('POST', FnosEndpoints.passwordLogin,
            status: 200, body: loginResponseSample());
      final p = FnosProvider(baseUrl: _base, adapter: fake);
      await p.login('u', 'h');

      final body = fake.last.body! as Map<String, dynamic>;
      expect(RegExp(r'^[a-f0-9]{32}$').hasMatch(body['deviceId'] as String), isTrue);
    });
  });

  group('URL 构造', () {
    test('stream URL 用 guid 参数', () {
      final c = _client(FakeAdapter());
      expect(
        c.buildStreamUrl('abc'),
        'http://example.local:5666/music/api/v1/track/stream?guid=abc',
      );
    });

    test('cover URL 用 coverId 完整值（含前缀），默认 size=200', () {
      final c = _client(FakeAdapter());
      final url = c.buildCoverUrl('album_659bfc696e7045bb85f07eb45022c0f2');
      expect(url, contains('coverId=album_659bfc696e7045bb85f07eb45022c0f2'));
      expect(url, contains('size=200'));
      expect(url, contains('/music/api/v1/static/cover?'));
    });

    test('cover URL 支持自定义 size；size<=0 时不带 size', () {
      final c = _client(FakeAdapter());
      expect(c.buildCoverUrl('artist_1', size: 120), contains('size=120'));
      expect(c.buildCoverUrl('track_1', size: 0), isNot(contains('size=')));
    });

    test('cover URL 不拆分前缀，并对特殊字符做转义', () {
      final c = _client(FakeAdapter());
      expect(c.buildCoverUrl('track_0123456789abcdef0123456789abcdef'),
          contains('coverId=track_0123456789abcdef0123456789abcdef'));
      expect(FnosClient.hasCoverPrefix('album_659bfc696e7045bb85f07eb45022c0f2'),
          isTrue);
      expect(FnosClient.hasCoverPrefix('noprefix'), isFalse);
    });

    test('deviceId 校验转发可用', () {
      expect(FnosClient.isValidDeviceId(testDeviceId), isTrue);
      expect(FnosClient.isValidDeviceId('short'), isFalse);
    });
  });

  group('端点常量（Phase 1 九个接口全部 VERIFIED）', () {
    test('路径与真实契约一致', () {
      expect(FnosEndpoints.apiBase, '/music/api/v1');
      expect(FnosEndpoints.initializationState, '/music/api/v1/initialization/state');
      expect(FnosEndpoints.passwordLogin, '/music/api/v1/user/password-login');
      expect(FnosEndpoints.userMe, '/music/api/v1/user/me');
      expect(FnosEndpoints.trackList, '/music/api/v1/track/list');
      expect(FnosEndpoints.albumList, '/music/api/v1/album/list');
      expect(FnosEndpoints.artistList, '/music/api/v1/artist/list');
      expect(FnosEndpoints.lyricList, '/music/api/v1/lyric/list');
      expect(FnosEndpoints.trackStream, '/music/api/v1/track/stream');
      expect(FnosEndpoints.staticCover, '/music/api/v1/static/cover');
    });

    test('分页与歌词参数名按实测', () {
      expect(FnosEndpoints.paramPage, 'page');
      expect(FnosEndpoints.paramSize, 'size');
      expect(FnosEndpoints.paramTrackGuid, 'trackGUID');
      expect(FnosEndpoints.paramCoverId, 'coverId');
      expect(FnosEndpoints.defaultPageSize, 50);
    });

    test('九个 Phase 1 接口都标记为已验证', () {
      expect(FnosEndpoints.phase1PathsVerified.length, 9);
      expect(FnosEndpoints.phase1PathsVerified.values.every((v) => v), isTrue);
    });
  });
}
