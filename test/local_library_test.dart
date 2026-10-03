import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/services/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_secure_store.dart';

/// 造一首可指定歌手 / 专辑 / 风格 / 收藏 / 入库时间的曲目。
///
/// `makeTrack()`（support/fake_music_repository.dart）的 artists 恒为空、
/// album 名恒为「专辑 <guid>」—— 那样测不出「分组取第一位歌手」这类分支，
/// 因此这里另造一个更可控的构造糖。
Track tr(
  String guid, {
  String artist = '',
  String album = '',
  List<String> genres = const <String>[],
  bool favorite = false,
  int? createdSec,
}) {
  return Track(
    guid: guid,
    title: '曲目 $guid',
    durationMs: 180000,
    isFavorite: favorite,
    genres: genres,
    createdAt: createdSec == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(createdSec * 1000),
    album: AlbumRef(guid: 'al_$guid', name: album),
    artists: artist.isEmpty
        ? const <ArtistRef>[]
        : <ArtistRef>[ArtistRef(guid: 'ar_$guid', name: artist)],
    audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
  );
}

/// 读取永远失败的存储：模拟部分 Android TV ROM 上 Keystore 不可用。
class _FailingStore extends SecureStore {
  @override
  Future<List<String>> readRecentGuids() async =>
      throw StateError('Keystore 不可用（模拟）');
}

void main() {
  group('最近播放（本机记录，飞牛无 play-history 接口）', () {
    test('记录后新的在前，重复播放会把它前移到首位', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      local.recordPlayed('a');
      local.recordPlayed('b');
      local.recordPlayed('c');
      expect(local.recentGuids, <String>['c', 'b', 'a']);

      local.recordPlayed('a'); // 重听老歌 → 提到最前
      expect(local.recentGuids, <String>['a', 'c', 'b']);
      expect(local.recentGuids.length, 3, reason: '同一首不能出现两次');
    });

    test('当前曲重复触发直接短路（进度刷新会反复回调）', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      var notified = 0;
      local.addListener(() => notified++);

      local.recordPlayed('a');
      local.recordPlayed('b');
      final after = notified;
      local.recordPlayed('b'); // 同一首、且已在首位 → 不该再通知
      local.recordPlayed('b');
      expect(notified, after, reason: '首位重复记录不应触发无谓的重排与写盘');
      expect(local.recentGuids, <String>['b', 'a']);
    });

    test('空 guid 被忽略', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);
      local.recordPlayed('');
      expect(local.hasRecent, isFalse);
    });

    test('超过上限时只保留最近 50 条', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      for (var i = 0; i < 60; i++) {
        local.recordPlayed('g$i');
      }
      expect(local.recentGuids.length, SecureStore.maxRecentTracks);
      expect(local.recentGuids.first, 'g59');
      expect(local.recentGuids.contains('g0'), isFalse, reason: '最早的应被挤掉');
      expect(local.recentGuids.last, 'g10');
    });

    test('Z 持久化往返：新实例 restore 后能读回同样的顺序', () async {
      // 用同一个 FakeSecureStore 造两个实例，模拟「退出 APP → 重启」。
      // ⚠️ 必须走真实的写 → 读往返，而不是给两个实例塞同一个内存字段,
      // 否则测不到「序列化格式」对不对。
      final store = FakeSecureStore();

      final first = LocalLibraryRepository(store: store);
      first.recordPlayed('a');
      first.recordPlayed('b');
      first.recordPlayed('c');
      // recordPlayed 的落盘是 unawaited 的，让 microtask 跑完
      await Future<void>.delayed(Duration.zero);
      first.dispose();

      final second = LocalLibraryRepository(store: store);
      addTearDown(second.dispose);
      expect(second.hasRecent, isFalse, reason: 'restore 之前应为空');

      await second.restore();
      expect(second.recentGuids, <String>['c', 'b', 'a']);
    });

    test('restore 失败（Keystore 不可用）→ 降级为空，不抛异常', () async {
      final local = LocalLibraryRepository(store: _FailingStore());
      addTearDown(local.dispose);

      // 启动路径上的任何异常都会变成「开机黑屏」，所以这里必须不抛
      await local.restore();
      expect(local.recentGuids, isEmpty);
    });

    test('recentTracks 还原为曲目，已从曲库删除的自动跳过', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      local.recordPlayed('a');
      local.recordPlayed('gone'); // 之后从服务器删掉了
      local.recordPlayed('b');

      final catalogue = <Track>[tr('a'), tr('b'), tr('c')];
      final restored = local.recentTracks(catalogue);
      expect(restored.map((t) => t.guid).toList(), <String>['b', 'a']);
    });

    test('曲库为空时 recentTracks 返回空列表（不抛）', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);
      local.recordPlayed('a');
      expect(local.recentTracks(const <Track>[]), isEmpty);
    });
  });

  group('收藏 / 最近添加', () {
    test('收藏直接用服务端 isFavorite，不在本地另存一份', () {
      final catalogue = <Track>[
        tr('a'),
        tr('b', favorite: true),
        tr('c', favorite: true),
      ];
      final favs = LocalLibraryRepository.favorites(catalogue);
      expect(favs.map((t) => t.guid).toList(), <String>['b', 'c']);
    });

    test('最近添加按 createdAt 倒序，无时间的沉底', () {
      final catalogue = <Track>[
        tr('old', createdSec: 1000),
        tr('none'),
        tr('new', createdSec: 3000),
        tr('mid', createdSec: 2000),
      ];
      final recent = LocalLibraryRepository.recentlyAdded(catalogue);
      expect(
        recent.map((t) => t.guid).toList(),
        <String>['new', 'mid', 'old', 'none'],
      );
    });

    test('最近添加遵守 limit', () {
      final catalogue = <Track>[
        for (var i = 0; i < 10; i++) tr('g$i', createdSec: 1000 + i),
      ];
      final recent = LocalLibraryRepository.recentlyAdded(catalogue, limit: 3);
      expect(recent.map((t) => t.guid).toList(), <String>['g9', 'g8', 'g7']);
    });

    test('空曲库不抛异常', () {
      expect(LocalLibraryRepository.favorites(const <Track>[]), isEmpty);
      expect(LocalLibraryRepository.recentlyAdded(const <Track>[]), isEmpty);
    });
  });

  group('分组视图', () {
    test('按歌手分组取第一位歌手，无歌手归入「未知歌手」', () {
      final catalogue = <Track>[
        tr('a', artist: '孙燕姿'),
        tr('b', artist: '周杰伦'),
        tr('c', artist: '孙燕姿'),
        tr('d'), // 无歌手
      ];
      final groups = LocalLibraryRepository.groupByArtist(catalogue);
      expect(groups.map((g) => g.title).toList(), <String>['周杰伦', '孙燕姿', '未知歌手']);
      expect(groups[1].subtitle, '2 首');
      expect(groups[1].tracks.map((t) => t.guid).toList(), <String>['a', 'c']);
      expect(groups[2].tracks.single.guid, 'd');
    });

    test('按专辑分组，无专辑名归入「未知专辑」', () {
      final catalogue = <Track>[
        tr('a', album: '叶惠美'),
        tr('b', album: '叶惠美'),
        tr('c'),
      ];
      // 分组标题按 `toLowerCase()` 后的码元序排列：
      // '叶'(U+53F6) < '未'(U+672A)，所以「叶惠美」在前。
      final groups = LocalLibraryRepository.groupByAlbum(catalogue);
      expect(groups.map((g) => g.title).toList(), <String>['叶惠美', '未知专辑']);
      expect(groups[0].tracks.length, 2);
      expect(groups[1].tracks.single.guid, 'c');
    });

    test('按风格分组：一首可出现在多个分组里', () {
      final catalogue = <Track>[
        tr('a', genres: <String>['摇滚', '流行']),
        tr('b', genres: <String>['流行']),
      ];
      // '摇'(U+6447) < '流'(U+6D41)
      final groups = LocalLibraryRepository.groupByGenre(catalogue);
      expect(groups.map((g) => g.title).toList(), <String>['摇滚', '流行']);
      expect(groups[0].tracks.single.guid, 'a');
      expect(groups[1].tracks.map((t) => t.guid).toList(), <String>['a', 'b']);
    });

    test('曲库完全没有风格标签 → 返回空列表（UI 应如实说「没有风格标签」）', () {
      final catalogue = <Track>[tr('a'), tr('b')];
      expect(LocalLibraryRepository.groupByGenre(catalogue), isEmpty);
    });

    test('风格标签里的空白串被忽略', () {
      final catalogue = <Track>[
        tr('a', genres: <String>['  ', '']),
      ];
      expect(LocalLibraryRepository.groupByGenre(catalogue), isEmpty);
    });
  });
}
