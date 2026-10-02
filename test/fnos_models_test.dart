import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/json_util.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fnos_samples.dart';

/// 领域模型契约测试 —— 全部基于**真实 NAS 实测样本**（已脱敏）。
///
/// 重点验证 Phase 1 早期猜测与真实结构的差异：
/// `id`→`guid`、`artistNames`→`artists[]`、`album.originalReleaseYear`→`album.releaseDate`、
/// `audioSpec.channels`→`audioSpec.channel`、`duration` 是毫秒、时间戳是 Unix 秒。
void main() {
  group('Track.fromJson（真实样本）', () {
    final t = Track.fromJson(trackSample());

    test('主键是 guid，标题/封面取自真实字段', () {
      expect(t.guid, '190294f1459e486291cab74dfc8da470');
      expect(t.title, '作战');
      expect(t.coverId, 'album_659bfc696e7045bb85f07eb45022c0f2');
    });

    test('duration 单位是毫秒（218711ms ≈ 218.7s ≈ 3分39秒）', () {
      expect(t.durationMs, 218711);
      expect(t.duration, const Duration(milliseconds: 218711));
      expect(t.duration.inSeconds, 218);
      // 前端权威映射：Math.round(duration / 1e3)
      expect((t.durationMs / 1000).round(), 219);
      // 若误当秒处理，会得到 60 小时级的荒谬时长
      expect(t.duration.inHours, lessThan(1));
    });

    test('audioSpec.duration 与顶层一致（同为毫秒）', () {
      expect(t.audioSpec.durationMs, 218711);
    });

    test('audiospec 声道字段是 channel（单数）', () {
      expect(t.audioSpec.channel, 2);
      expect(t.audioSpec.bitDepth, 16);
      expect(t.audioSpec.sampleRate, 44100);
      expect(t.audioSpec.bitrate, 962854);
      expect(t.audioSpec.format, 'flac');
      expect(t.audioSpec.codec, 'flac');
    });

    test('规格串可读', () {
      expect(t.audioSpec.display, contains('FLAC'));
      expect(t.audioSpec.display, contains('16bit'));
      expect(t.audioSpec.display, contains('44kHz'));
    });

    test('歌手来自 artists 数组（不是 artistNames 字符串）', () {
      expect(t.artists.length, 1);
      expect(t.artists.first.name, '孙燕姿');
      expect(t.artists.first.guid, 'f68ba53c0fbf413cafe03b9d19eff378');
      expect(t.artistNames, '孙燕姿');
    });

    test('album 内嵌引用：name / releaseDate / barcode / 时间戳', () {
      expect(t.album.name, 'Leave');
      expect(t.album.releaseDate, '2002');
      expect(t.album.barcode, '825646671045');
      expect(t.album.coverId, 'album_659bfc696e7045bb85f07eb45022c0f2');
    });

    test('releaseYear 取 album.releaseDate 前四位（顶层 year 实测为 null）', () {
      expect(t.year, isNull);
      expect(t.album.releaseDate, '2002');
      expect(t.releaseYear, 2002);
    });

    test('createdAt / updatedAt 是 Unix 秒（不是毫秒）', () {
      expect(t.createdAt, isNotNull);
      expect(t.createdAt!.toUtc().year, 2026);
      expect(t.createdAt!.toUtc().month, 9);
      expect(t.updatedAt!.toUtc().year, 2026);
    });

    test('新增字段：isrc / isFavorite / isCue / genres', () {
      expect(t.isrc, 'TWA530224201');
      expect(t.isFavorite, isFalse);
      expect(t.isCue, isFalse);
      expect(t.genres, isEmpty);
      expect(t.discNo, 1);
      expect(t.trackNo, 1);
    });
  });

  group('coverId 必须保留前缀', () {
    test('track.coverId 存在时优先使用它', () {
      final t = Track.fromJson(trackSample());
      expect(t.effectiveCoverId, startsWith('album_'));
      expect(t.effectiveCoverId, 'album_659bfc696e7045bb85f07eb45022c0f2');
    });

    test('track.coverId 缺失时回退到 album.coverId', () {
      final t = Track.fromJson(<String, dynamic>{
        'guid': 'g',
        'title': 't',
        'coverId': null,
        'album': <String, dynamic>{
          'guid': 'a',
          'name': 'A',
          'coverId': 'album_11111111111111111111111111111111',
        },
        'artists': <dynamic>[],
      });
      expect(t.effectiveCoverId, 'album_11111111111111111111111111111111');
    });

    test('两者都缺失时为 null，且不伪造前缀', () {
      final t = Track.fromJson(<String, dynamic>{
        'guid': 'g',
        'title': 't',
        'album': <String, dynamic>{},
        'artists': <dynamic>[],
      });
      expect(t.effectiveCoverId, isNull);
    });

    test('artist / track 前缀原样保留（不做任何拆分）', () {
      for (final prefix in <String>['album', 'artist', 'track']) {
        final id = '${prefix}_0123456789abcdef0123456789abcdef';
        final t = Track.fromJson(<String, dynamic>{
          'guid': 'g',
          'title': 't',
          'coverId': id,
          'album': <String, dynamic>{},
          'artists': <dynamic>[],
        });
        expect(t.effectiveCoverId, id);
        expect(t.effectiveCoverId!.split('_').first, prefix);
      }
    });
  });

  group('容错', () {
    test('缺可选字段不崩溃', () {
      final t = Track.fromJson(<String, dynamic>{
        'guid': 'g',
        'title': 't',
        'album': <String, dynamic>{},
        'artists': <dynamic>[],
      });
      expect(t.coverId, isNull);
      expect(t.audioSpec.format, isNull);
      expect(t.audioSpec.channel, isNull);
      expect(t.artistNames, isEmpty);
      expect(t.durationMs, 0);
      expect(t.createdAt, isNull);
      expect(t.accessStatus, 0);
      expect(t.isAccessible, isTrue);
    });

    test('accessStatus=3 标记失效不可播', () {
      final t = Track.fromJson(<String, dynamic>{
        'guid': 'g',
        'title': 't',
        'accessStatus': 3,
        'album': <String, dynamic>{},
        'artists': <dynamic>[],
      });
      expect(t.isAccessible, isFalse);
    });

    test('异常类型（数字/字符串/非 Map）一律兜底', () {
      final t = Track.fromJson(<String, dynamic>{
        'guid': 123,
        'title': null,
        'duration': '60000',
        'genres': 'not-a-list',
        'artists': <dynamic>[
          1,
          'x',
          <String, dynamic>{'name': 'ok'},
        ],
        'audioSpec': 'bad',
        'album': <dynamic>[],
      });
      expect(t.guid, '123');
      expect(t.title, '');
      expect(t.durationMs, 60000);
      expect(t.genres, isEmpty);
      expect(t.artists.length, 1);
      expect(t.artists.single.name, 'ok');
      expect(t.audioSpec.format, isNull);
      expect(t.album.isEmpty, isTrue);
    });
  });

  group('Album.fromJson（真实样本）', () {
    final a = Album.fromJson(albumSample());

    test('字段完整', () {
      expect(a.guid, 'a1b2c3d4e5f60718293a4b5c6d7e8f90');
      expect(a.name, 'Leave');
      expect(a.coverId, startsWith('album_'));
      expect(a.releaseDate, '2002');
      expect(a.barcode, '825646671045');
      expect(a.trackCount, 12);
      expect(a.artists.single.name, '孙燕姿');
    });

    test('releaseDate 解析出年份；缺失时为 null', () {
      expect(a.releaseYear, 2002);
      expect(
        Album.fromJson(<String, dynamic>{'guid': 'g', 'name': 'n'}).releaseYear,
        isNull,
      );
    });

    test('时间戳为 Unix 秒', () {
      expect(a.createdAt!.toUtc().year, 2026);
      expect(a.updatedAt!.toUtc().year, 2026);
    });
  });

  group('Artist.fromJson（真实样本）', () {
    final a = Artist.fromJson(artistSample());

    test('字段完整', () {
      expect(a.guid, 'f68ba53c0fbf413cafe03b9d19eff378');
      expect(a.name, '孙燕姿');
      expect(a.coverId, startsWith('artist_'));
      expect(a.trackCount, 128);
      expect(a.albumCount, 14);
      expect(a.createdAt!.toUtc().year, 2026);
    });

    test('artist/list-all 的轻量形态也能解析', () {
      final light = Artist.fromJson(<String, dynamic>{
        'guid': 'g',
        'name': 'n',
        'coverId': 'artist_0123456789abcdef0123456789abcdef',
        'createdAt': 1788262195,
        'updatedAt': 1788262195,
      });
      expect(light.trackCount, 0);
      expect(light.albumCount, 0);
      expect(light.coverId, startsWith('artist_'));
    });
  });

  group('jsonUnixSeconds', () {
    test('秒 → DateTime；疑似毫秒自动收敛', () {
      expect(jsonUnixSeconds(1788283180)!.toUtc().year, 2026);
      expect(jsonUnixSeconds(1788283180000)!.toUtc().year, 2026);
    });

    test('0 / 负数 / null / 非数字返回 null', () {
      expect(jsonUnixSeconds(0), isNull);
      expect(jsonUnixSeconds(-1), isNull);
      expect(jsonUnixSeconds(null), isNull);
      expect(jsonUnixSeconds('abc'), isNull);
    });
  });
}
