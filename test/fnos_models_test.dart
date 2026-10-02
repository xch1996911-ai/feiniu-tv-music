import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Track.fromJson', () {
    test('解析完整字段', () {
      final t = Track.fromJson({
        'guid': 'g1',
        'title': 'Song',
        'coverId': 'c1',
        'duration': 180000,
        'album': {'guid': 'a1', 'name': 'Album', 'coverId': 'ca'},
        'artists': [
          {'guid': 'ar1', 'name': 'Artist', 'coverId': 'cr'}
        ],
        'audioSpec': {
          'format': 'FLAC',
          'sampleRate': 96000,
          'bitDepth': 24,
          'bitrate': 1234
        },
        'hasLyric': true,
        'accessStatus': 1,
      });

      expect(t.guid, 'g1');
      expect(t.title, 'Song');
      expect(t.durationMs, 180000);
      expect(t.album.name, 'Album');
      expect(t.artists.length, 1);
      expect(t.artists.first.name, 'Artist');
      expect(t.audioSpec.format, 'FLAC');
      expect(t.audioSpec.sampleRate, 96000);
      expect(t.hasLyric, true);
      expect(t.isAccessible, true);
      expect(t.audioSpec.display, contains('FLAC'));
      expect(t.audioSpec.display, contains('24bit'));
      expect(t.audioSpec.display, contains('96kHz'));
    });

    test('accessStatus=3 标记失效不可播', () {
      final t = Track.fromJson({
        'guid': 'g',
        'title': 't',
        'accessStatus': 3,
        'album': <String, dynamic>{},
        'artists': <dynamic>[],
      });
      expect(t.isAccessible, false);
    });

    test('缺少可选字段不崩溃', () {
      final t = Track.fromJson({
        'guid': 'g',
        'title': 't',
        'accessStatus': 1,
        'album': <String, dynamic>{},
        'artists': <dynamic>[],
      });
      expect(t.coverId, isNull);
      expect(t.audioSpec.format, isNull);
      expect(t.artistNames, isEmpty);
    });
  });

  group('Album / Artist', () {
    test('Album.fromJson', () {
      final a = Album.fromJson(
          {'guid': 'a', 'name': 'N', 'coverId': 'c', 'trackCount': 10});
      expect(a.trackCount, 10);
    });
    test('Artist.fromJson', () {
      final a = Artist.fromJson({
        'guid': 'a',
        'name': 'N',
        'coverId': 'c',
        'trackCount': 5,
        'albumCount': 2
      });
      expect(a.albumCount, 2);
    });
  });
}
