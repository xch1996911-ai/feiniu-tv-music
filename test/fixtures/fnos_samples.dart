/// 真实 NAS 响应的**脱敏** fixture。
///
/// 来源：`fnOS_API_真实契约.md` §1.2 / §3 / §5 的实测样本。
///
/// ## 脱敏规则（需求 §十一）
/// **不得**写入真实 NAS IP、用户名、token、音乐文件绝对路径。本文件已按此处理：
/// - host / IP —— 一律使用 `example.local` 之类占位；
/// - 用户名 —— `testuser`；
/// - token —— 人造 32 位 hex（与真实 token 无任何关系）；
/// - `audioSpec.path` —— 替换为 `/music/test/01.flac`（真实值是 NAS 绝对路径）。
///
/// 保留原样的只有**非敏感的音乐元数据**与**不透明资源 ID**
/// （曲名、专辑名、歌手名、`guid`、`coverId`），因为测试的价值正在于
/// 用真实形状验证解析与「coverId 前缀必须保留」这类契约。
library;

/// 一个真实的登录成功响应（已脱敏）。
Map<String, dynamic> loginResponseSample({String token = testToken}) => {
      'code': 0,
      'msg': '',
      'data': {
        'userToken': token,
        'user': {
          'guid': '0f1e2d3c4b5a69788796a5b4c3d2e1f0',
          'name': 'testuser',
          'role': 'admin',
          'lastAccessedAt': 1789831867,
          'createdAt': 1788189112,
          'updatedAt': 1789831873,
        },
      },
    };

/// 人造 token（32 位小写 hex）。
const String testToken = 'abcdef0123456789abcdef0123456789';

/// 人造 deviceId（32 位小写 hex）。
const String testDeviceId = '0123456789abcdef0123456789abcdef';

/// 真实 Track 样本（实测于真实 NAS，路径字段已脱敏）。
Map<String, dynamic> trackSample() => {
      'guid': '190294f1459e486291cab74dfc8da470',
      'title': '作战',
      'coverId': 'album_659bfc696e7045bb85f07eb45022c0f2',
      'year': null,
      'discNo': 1,
      'trackNo': 1,
      'isrc': 'TWA530224201',
      'duration': 218711, // 毫秒（实测：218.7 秒）
      'isCue': false,
      'createdAt': 1788283180, // Unix 秒
      'updatedAt': 1788283180,
      'album': {
        'guid': 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
        'name': 'Leave',
        'coverId': 'album_659bfc696e7045bb85f07eb45022c0f2',
        'releaseDate': '2002',
        'barcode': '825646671045',
        'createdAt': 1788283180,
        'updatedAt': 1788283180,
      },
      'artists': [
        {
          'guid': 'f68ba53c0fbf413cafe03b9d19eff378',
          'name': '孙燕姿',
          'coverId': 'artist_f68ba53c0fbf413cafe03b9d19eff378',
          'createdAt': 1788262195,
          'updatedAt': 1788262195,
        }
      ],
      'genres': <String>[],
      'audioSpec': {
        'bitDepth': 16,
        'sampleRate': 44100,
        'channel': 2, // ⚠️ 单数
        'bitrate': 962854,
        'codec': 'flac',
        'container': '',
        'duration': 218711,
        'format': 'flac',
        'path': '/music/test/01.flac', // 已脱敏（真实值为 NAS 绝对路径）
        'size': 26322832,
      },
      'isFavorite': false,
    };

/// 真实 Album 样本（实测键集：
/// `guid/name/coverId/releaseDate/barcode/createdAt/updatedAt/artists/trackCount`）。
Map<String, dynamic> albumSample() => {
      'guid': 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
      'name': 'Leave',
      'coverId': 'album_659bfc696e7045bb85f07eb45022c0f2',
      'releaseDate': '2002',
      'barcode': '825646671045',
      'createdAt': 1788283180,
      'updatedAt': 1788283180,
      'artists': [
        {'guid': 'f68ba53c0fbf413cafe03b9d19eff378', 'name': '孙燕姿'},
      ],
      'trackCount': 12,
    };

/// 真实 Artist 样本（实测键集：
/// `guid/name/coverId/createdAt/updatedAt/trackCount/albumCount`）。
Map<String, dynamic> artistSample() => {
      'guid': 'f68ba53c0fbf413cafe03b9d19eff378',
      'name': '孙燕姿',
      'coverId': 'artist_f68ba53c0fbf413cafe03b9d19eff378',
      'createdAt': 1788262195,
      'updatedAt': 1788262195,
      'trackCount': 128,
      'albumCount': 14,
    };

/// 真实 `track/list` 响应外层信封（实测结构：`{list,total,sort}`）。
Map<String, dynamic> trackListResponse({
  int total = 1,
  List<Map<String, dynamic>>? list,
}) =>
    {
      'code': 0,
      'msg': '',
      'data': {
        'list': list ?? [trackSample()],
        'total': total,
        'sort': 0,
      },
    };

/// 实测错误响应：缺 token / token 失效（HTTP 401）。
Map<String, dynamic> invalidTokenResponse() => {
      'code': 99999,
      'msg': 'INVALID TOKEN',
    };

/// 实测错误响应：凭据错误（**不是** token 失效）。
Map<String, dynamic> unauthorizedResponse() => {
      'code': 120001,
      'msg': 'unauthorized, please login again',
    };

/// 实测错误响应：缺 deviceId。
Map<String, dynamic> unknownErrorResponse() => {
      'code': 100001,
      'msg': 'unknown error',
    };

/// 实测错误响应：lyric/list 用了 `guid` 而不是 `trackGUID`。
Map<String, dynamic> invalidArgsResponse() => {
      'code': 100002,
      'msg': 'InvalidArgs',
    };

/// 歌词响应样本。
///
/// ⚠️ 真实 NAS 验证阶段**未取到**歌词样本，这里是按契约 §7 的结构
/// （`{list:[...], preferred:...}` + 单条含 `text/time/duration/offset`）
/// 构造的形状样本，用于验证解析器对两种形态都健壮。
Map<String, dynamic> lyricListResponse() => {
      'code': 0,
      'msg': '',
      'data': {
        'list': [
          {'guid': 'lyric-a', 'name': 'embedded', 'text': ''},
          {
            'guid': 'lyric-b',
            'name': 'external.lrc',
            'text': '[ar:孙燕姿]\n'
                '[ti:作战]\n'
                '[offset:0]\n'
                '[00:00.00]\n'
                '[00:12.34]第一行\n'
                '[01:05.50]第二行\n'
                '[02:30.00]第三行\n',
          },
        ],
        'preferred': 1,
      },
    };
