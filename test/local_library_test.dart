import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/player_layout.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/services/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_secure_store.dart';

/// 造一首可指定歌手 / 专辑 / 风格 / 收藏 / 入库时间的曲目。
///
/// `makeTrack()`（support/fake_music_repository.dart）的 artists 恒为空、
/// album 名恒为「专辑 <guid>」—— 那样测不出「多歌手 / 封面优先级」这类分支，
/// 因此这里另造一个更可控的构造糖。
///
/// ⚠️ **`artistGuid` 默认是 `'ar_<曲目 guid>'`，即「每首歌各自一个歌手」**。
/// 想表达「同一位歌手的多首歌」必须**显式传同一个 `artistGuid`**，
/// 否则数据层会把它们（正确地）当成两个同名的不同歌手 ——
/// 本项目真实踩过这个坑：歌手概览因此多出一个重复分组。
Track tr(
  String guid, {
  String artist = '',
  String? artistGuid,
  String? artistCover,
  String album = '',
  String? albumName,
  String? albumGuid,
  String? albumCover,
  String? trackCover,
  List<String> genres = const <String>[],
  bool favorite = false,
  int? createdSec,
  List<ArtistRef>? artists,
}) {
  final String albumTitle = albumName ?? album;
  return Track(
    guid: guid,
    title: '曲目 $guid',
    coverId: trackCover,
    durationMs: 180000,
    isFavorite: favorite,
    genres: genres,
    createdAt: createdSec == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(createdSec * 1000),
    album: AlbumRef(
      guid: albumGuid ?? 'al_$guid',
      name: albumTitle,
      coverId: albumCover,
    ),
    artists: artists ??
        (artist.isEmpty
            ? const <ArtistRef>[]
            : <ArtistRef>[
                ArtistRef(
                  guid: artistGuid ?? 'ar_$guid',
                  name: artist,
                  coverId: artistCover,
                ),
              ]),
    audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
  );
}

/// 读取「最近播放」永远失败的存储：模拟部分 Android TV ROM 上 Keystore 不可用。
///
/// ⚠️ 必须 `extends FakeSecureStore`（而不是裸 `SecureStore`）：
/// 否则另外三个读取会打到 `flutter_secure_storage` 的平台通道上抛
/// `MissingPluginException`，`Future.wait` 一样会失败 ——
/// 测试就「绿得不明不白」，测不到「只有最近播放这一个键读失败」这条分支。
class _FailingStore extends FakeSecureStore {
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
      // ⚠️ 必须走真实的写 → 读往返，而不是给两个实例塞同一个内存字段，
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
      expect(local.favoriteCount, 0);
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

    test('recentTracks 顺序 = 最近播放时间倒序（不是曲库顺序）', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      // 曲库顺序是 a,b,c；播放顺序是 c → a
      local.recordPlayed('c');
      local.recordPlayed('a');

      final catalogue = <Track>[tr('a'), tr('b'), tr('c')];
      final restored = local.recentTracks(catalogue);
      expect(
        restored.map((t) => t.guid).toList(),
        <String>['a', 'c'],
        reason: '「最近」必须按播放时间倒序，绝不能退化成显示全曲库',
      );
      expect(restored.length, lessThan(catalogue.length));
    });

    test('曲库为空时 recentTracks 返回空列表（不抛）', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);
      local.recordPlayed('a');
      expect(local.recentTracks(const <Track>[]), isEmpty);
    });
  });

  group('收藏（飞牛无写接口 → 本机集合是唯一数据源）', () {
    test('默认没有收藏，空 guid 的切换被忽略', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      expect(local.favoriteCount, 0);
      expect(local.isFavorite('a'), isFalse);

      expect(await local.toggleFavorite(''), isFalse);
      expect(local.favoriteCount, 0, reason: '空 guid 不能进集合');
      expect(local.isFavorite(''), isFalse);
    });

    test('toggleFavorite 立即改变内存状态，并返回切换后的结果', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      expect(await local.toggleFavorite('a'), isTrue);
      expect(local.isFavorite('a'), isTrue);
      expect(local.favoriteCount, 1);

      expect(await local.toggleFavorite('a'), isFalse);
      expect(local.isFavorite('a'), isFalse, reason: '取消收藏后必须立刻消失');
      expect(local.favoriteCount, 0);
    });

    test('收藏与取消收藏都会持久化（新实例 restore 后一致）', () async {
      final store = FakeSecureStore();

      final first = LocalLibraryRepository(store: store);
      await first.toggleFavorite('keep');
      await first.toggleFavorite('drop');
      await first.toggleFavorite('drop'); // 再取消掉
      first.dispose();

      final second = LocalLibraryRepository(store: store);
      addTearDown(second.dispose);
      expect(second.isFavorite('keep'), isFalse, reason: 'restore 之前应为空');

      await second.restore();
      expect(second.isFavorite('keep'), isTrue);
      expect(
        second.isFavorite('drop'),
        isFalse,
        reason: '取消收藏必须一并落盘，否则重启后「复活」',
      );
    });

    test('favoriteTracks 只认本机集合，**不认** Track.isFavorite', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      final catalogue = <Track>[
        tr('a'),
        tr('b', favorite: true), // 服务端说收藏，但本机还没播种
        tr('c', favorite: true),
      ];

      // 未播种 → 本机集合为空 → 收藏页必须是空的
      expect(local.favoriteTracks(catalogue), isEmpty);

      await local.toggleFavorite('a');
      expect(
        local.favoriteTracks(catalogue).map((t) => t.guid).toList(),
        <String>['a'],
        reason: '数据源只能是本机集合，避免服务端/本机两份状态互相打架',
      );
    });

    test('首次播种：把服务端 isFavorite 一次性导入', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      expect(local.favoritesSeeded, isFalse);
      final catalogue = <Track>[
        tr('a'),
        tr('b', favorite: true),
        tr('c', favorite: true),
      ];
      await local.seedFavoritesIfNeeded(catalogue);

      expect(local.favoritesSeeded, isTrue);
      expect(
        local.favoriteTracks(catalogue).map((t) => t.guid).toList(),
        <String>['b', 'c'],
      );
    });

    test('空曲库不播种（否则会把「还没加载完」误判成「服务端没收藏」）', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      await local.seedFavoritesIfNeeded(const <Track>[]);
      expect(local.favoritesSeeded, isFalse, reason: '空曲库不能置播种标记');
    });

    test('播种只做一次：用户全部取消后不会被服务端「复活」', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      final catalogue = <Track>[tr('b', favorite: true)];
      await local.seedFavoritesIfNeeded(catalogue);
      expect(local.isFavorite('b'), isTrue);

      await local.toggleFavorite('b'); // 用户取消收藏 → 集合变空
      expect(local.favoriteCount, 0);

      // 再播种一次（例如 Shell 重启、bootstrap 再跑）：必须**不**生效
      await local.seedFavoritesIfNeeded(catalogue);
      expect(
        local.isFavorite('b'),
        isFalse,
        reason: '播种标记必须单独存，不能靠「集合非空」判断',
      );
    });

    test('播种标记也会持久化', () async {
      final store = FakeSecureStore();
      final first = LocalLibraryRepository(store: store);
      await first.seedFavoritesIfNeeded(<Track>[tr('b', favorite: true)]);
      first.dispose();

      final second = LocalLibraryRepository(store: store);
      addTearDown(second.dispose);
      await second.restore();
      expect(second.favoritesSeeded, isTrue);
      expect(second.isFavorite('b'), isTrue);
    });

    test('空曲库时 favoriteTracks 返回空', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);
      await local.toggleFavorite('a');
      expect(local.favoriteTracks(const <Track>[]), isEmpty);
    });
  });

  group('最近添加（按入库时间，与「最近播放」是两个概念）', () {
    test('按 createdAt 倒序，无时间的沉底', () {
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

    test('遵守 limit', () {
      final catalogue = <Track>[
        for (var i = 0; i < 10; i++) tr('g$i', createdSec: 1000 + i),
      ];
      final recent = LocalLibraryRepository.recentlyAdded(catalogue, limit: 3);
      expect(recent.map((t) => t.guid).toList(), <String>['g9', 'g8', 'g7']);
    });

    test('重复 guid 只保留一次', () {
      final catalogue = <Track>[
        tr('a', createdSec: 1000),
        tr('a', createdSec: 1000),
        tr('b', createdSec: 2000),
      ];
      final recent = LocalLibraryRepository.recentlyAdded(catalogue);
      expect(recent.map((t) => t.guid).toList(), <String>['b', 'a']);
    });

    test('全部没有添加时间 → 不伪造顺序，按曲库原顺序返回', () {
      final catalogue = <Track>[tr('a'), tr('b'), tr('c')];
      final recent = LocalLibraryRepository.recentlyAdded(catalogue);
      expect(recent.length, 3, reason: '没有时间时不该丢掉曲目，只是无法排序');
    });

    test('空曲库不抛异常', () {
      expect(LocalLibraryRepository.recentlyAdded(const <Track>[]), isEmpty);
    });

    test('「最近添加」与「最近播放」互不影响', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      final catalogue = <Track>[
        tr('a', createdSec: 3000), // 最新入库
        tr('b', createdSec: 1000),
      ];
      // 实际播放的是 b
      local.recordPlayed('b');

      expect(
        local.recentTracks(catalogue).map((t) => t.guid).toList(),
        <String>['b'],
        reason: '「最近播放」按播放时间',
      );
      expect(
        LocalLibraryRepository.recentlyAdded(catalogue)
            .map((t) => t.guid)
            .toList(),
        <String>['a', 'b'],
        reason: '「最近添加」按入库时间 —— 两者不能混成一页',
      );
    });
  });

  group('歌手概览', () {
    test('计数正确：同一歌手多首合并，未知歌手兜底', () {
      final catalogue = <Track>[
        // ⚠️ 同一位歌手必须用**同一个 artistGuid**（见 `tr()` 的说明）：
        //    飞牛返回的 artists 里 guid 才是身份，重名歌手不能靠名字合并。
        tr('a', artist: '孙燕姿', artistGuid: 'ar_syz'),
        tr('b', artist: '周杰伦', artistGuid: 'ar_jl'),
        tr('c', artist: '孙燕姿', artistGuid: 'ar_syz'),
        tr('d'), // 无歌手
      ];
      final groups = LocalLibraryRepository.artistOverviews(catalogue);

      expect(
        groups.map((g) => g.title).toList(),
        <String>['孙燕姿', '周杰伦', LocalLibraryRepository.unknownArtist],
      );
      // 歌曲数降序
      expect(groups[0].trackCount, 2);
      expect(groups[1].trackCount, 1);
      expect(groups[2].trackCount, 1);

      // 详情页要用的曲目清单
      expect(groups[0].tracks.map((t) => t.guid).toList(), <String>['a', 'c']);
      expect(groups[2].tracks.single.guid, 'd');
    });

    test('专辑数按**去重专辑**统计（歌手概览的第二行统计）', () {
      final catalogue = <Track>[
        // ⚠️ 同一张专辑必须共用一个 albumGuid，否则在数据层看来就是两张专辑；
        //    同一位歌手同理必须共用 artistGuid（否则会拆成两个歌手分组）。
        tr('a', artist: '孙燕姿', artistGuid: 'ar_syz',
            albumName: '同一张', albumGuid: 'alb_1'),
        tr('b', artist: '孙燕姿', artistGuid: 'ar_syz',
            albumName: '同一张', albumGuid: 'alb_1'),
        tr('c', artist: '孙燕姿', artistGuid: 'ar_syz',
            albumName: '另一张', albumGuid: 'alb_2'),
      ];
      final g = LocalLibraryRepository.artistOverviews(catalogue).single;
      expect(g.trackCount, 3);
      expect(g.albumCount, 2, reason: '3 首歌分布在 2 张专辑上');
      expect(g.subtitle, isNull, reason: '歌手概览不展示副标题');
    });

    test('合唱曲目同时计入每位歌手（因此各歌手歌曲数之和可大于曲库总数）', () {
      final catalogue = <Track>[
        tr(
          'duet',
          artists: const <ArtistRef>[
            ArtistRef(guid: 'ar_a', name: '歌手甲'),
            ArtistRef(guid: 'ar_b', name: '歌手乙'),
          ],
        ),
      ];
      final groups = LocalLibraryRepository.artistOverviews(catalogue);
      expect(groups.length, 2);
      expect(
        groups.map((g) => g.title).toSet(),
        <String>{'歌手甲', '歌手乙'},
      );
      for (final g in groups) {
        expect(g.trackCount, 1, reason: '合唱曲目必须同时出现在两位歌手名下');
      }
      expect(
        groups.fold<int>(0, (int s, g) => s + g.trackCount),
        greaterThan(catalogue.length),
      );
    });

    test('同一首歌在分页合并中重复出现时只计一次', () {
      final catalogue = <Track>[
        tr('a', artist: '孙燕姿'),
        tr('a', artist: '孙燕姿'), // 合并分页带来的重复
        tr('a', artist: '孙燕姿'),
      ];
      final g = LocalLibraryRepository.artistOverviews(catalogue).single;
      expect(g.trackCount, 1, reason: '重复 guid 不能把统计撑大');
      expect(g.tracks.length, 1);
    });

    test('歌手头像优先于曲目封面；都没有时退回曲目封面', () {
      final catalogue = <Track>[
        tr(
          'a',
          artists: const <ArtistRef>[
            ArtistRef(guid: 'ar_a', name: '有头像', coverId: 'artist_aaa'),
          ],
          trackCover: 'track_aaa',
        ),
        tr(
          'b',
          artists: const <ArtistRef>[
            ArtistRef(guid: 'ar_b', name: '没头像'),
          ],
          trackCover: 'track_bbb',
        ),
      ];
      final groups = LocalLibraryRepository.artistOverviews(catalogue);
      final byTitle = <String, LibraryOverview>{
        for (final g in groups) g.title: g,
      };
      expect(byTitle['有头像']!.coverId, 'artist_aaa',
          reason: 'artist.coverId 是歌手专用图，必须优先');
      expect(byTitle['没头像']!.coverId, 'track_bbb',
          reason: '歌手没头像时退回曲目封面兜底');
    });

    test('key 用 guid 而非显示名（重名歌手不会串位）', () {
      final catalogue = <Track>[
        tr('a', artistGuid: 'ar_1', artist: '同名'),
        tr('b', artistGuid: 'ar_2', artist: '同名'),
      ];
      final groups = LocalLibraryRepository.artistOverviews(catalogue);
      expect(groups.length, 2, reason: 'guid 不同 → 是两个歌手');
      expect(groups.map((g) => g.key).toSet(), <String>{'a:ar_1', 'a:ar_2'});
    });

    test('name / guid 全空的歌手条目被跳过，不造「未知歌手」', () {
      final catalogue = <Track>[
        tr(
          'a',
          artists: const <ArtistRef>[ArtistRef(guid: '', name: '')],
        ),
      ];
      expect(
        LocalLibraryRepository.artistOverviews(catalogue),
        isEmpty,
        reason: '残缺条目应跳过，而不是凭空造一个歌手',
      );
    });

    test('空曲库返回空列表', () {
      expect(LocalLibraryRepository.artistOverviews(const <Track>[]), isEmpty);
    });
  });

  group('专辑概览', () {
    test('计数正确、副标题取首位歌手、无专辑名归入「未知专辑」', () {
      final catalogue = <Track>[
        // 同一张专辑必须共用一个 albumGuid
        tr('a', albumName: '叶惠美', albumGuid: 'alb_ye', artist: '周杰伦'),
        tr('b', albumName: '叶惠美', albumGuid: 'alb_ye', artist: '周杰伦'),
        tr('c', artist: '孙燕姿'), // album 名为空
      ];
      final groups = LocalLibraryRepository.albumOverviews(catalogue);
      // 按专辑名排序：'叶'(U+53F6) < '未'(U+672A)
      expect(
        groups.map((g) => g.title).toList(),
        <String>['叶惠美', LocalLibraryRepository.unknownAlbum],
      );
      expect(groups[0].trackCount, 2);
      expect(groups[0].subtitle, '周杰伦', reason: '专辑名下方显示歌手（参考图三）');
      expect(groups[0].tracks.map((t) => t.guid).toList(), <String>['a', 'b']);
      expect(groups[1].trackCount, 1);
      expect(groups[1].subtitle, '孙燕姿');
    });

    test('专辑封面优先于曲目封面', () {
      final catalogue = <Track>[
        tr('a', albumName: '有封面', albumCover: 'album_aaa', trackCover: 't_a'),
        tr('b', albumName: '无封面', trackCover: 't_b'),
      ];
      final byTitle = <String, LibraryOverview>{
        for (final g in LocalLibraryRepository.albumOverviews(catalogue))
          g.title: g,
      };
      expect(byTitle['有封面']!.coverId, 'album_aaa');
      expect(byTitle['无封面']!.coverId, 't_b');
    });

    test('同一专辑的不同曲目只计一次歌，专辑数不参与', () {
      final catalogue = <Track>[
        tr('a', albumName: '专辑X', albumGuid: 'alb_x'),
        tr('a', albumName: '专辑X', albumGuid: 'alb_x'),
      ];
      final g = LocalLibraryRepository.albumOverviews(catalogue).single;
      expect(g.trackCount, 1);
      expect(g.albumCount, 0, reason: '专辑概览不需要专辑数');
    });

    test('无歌手时副标题回落到「未知歌手」', () {
      final catalogue = <Track>[tr('a', albumName: '纯音乐')];
      final g = LocalLibraryRepository.albumOverviews(catalogue).single;
      expect(g.subtitle, LocalLibraryRepository.unknownArtist);
    });

    test('空曲库返回空列表', () {
      expect(LocalLibraryRepository.albumOverviews(const <Track>[]), isEmpty);
    });
  });

  group('风格概览', () {
    test('一首可出现在多个风格分组里', () {
      final catalogue = <Track>[
        tr('a', genres: <String>['摇滚', '流行']),
        tr('b', genres: <String>['流行']),
      ];
      // '摇'(U+6447) < '流'(U+6D41)
      final groups = LocalLibraryRepository.genreOverviews(catalogue);
      expect(
        groups.map((g) => g.title).toList(),
        <String>['摇滚', '流行'],
      );
      expect(groups[0].trackCount, 1);
      expect(groups[0].tracks.single.guid, 'a');
      expect(groups[1].trackCount, 2);
      expect(groups[1].tracks.map((t) => t.guid).toList(), <String>['a', 'b']);
    });

    test('曲库完全没有风格标签 → 返回空列表（UI 应如实说「暂无风格标签」）', () {
      final catalogue = <Track>[tr('a'), tr('b')];
      expect(
        LocalLibraryRepository.genreOverviews(catalogue),
        isEmpty,
        reason: '绝不能把全部歌曲塞进「未知风格」来假装有数据',
      );
    });

    test('风格标签里的空白串被忽略', () {
      final catalogue = <Track>[
        tr('a', genres: <String>['  ', '']),
      ];
      expect(LocalLibraryRepository.genreOverviews(catalogue), isEmpty);
    });

    test('空曲库返回空列表', () {
      expect(LocalLibraryRepository.genreOverviews(const <Track>[]), isEmpty);
    });
  });

  group('播放页展示模式偏好', () {
    test('默认是标准布局', () {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);
      expect(local.playerLayout, PlayerLayout.stage);
    });

    test('切换后立即生效', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      await local.setPlayerLayout(PlayerLayout.cover);
      expect(local.playerLayout, PlayerLayout.cover);
      await local.setPlayerLayout(PlayerLayout.stage);
      expect(local.playerLayout, PlayerLayout.stage);
    });

    test('偏好会持久化 —— 重新打开播放器后保留上次选择', () async {
      final store = FakeSecureStore();
      final first = LocalLibraryRepository(store: store);
      await first.setPlayerLayout(PlayerLayout.cover);
      first.dispose();

      final second = LocalLibraryRepository(store: store);
      addTearDown(second.dispose);
      expect(second.playerLayout, PlayerLayout.stage, reason: 'restore 之前是默认值');

      await second.restore();
      expect(second.playerLayout, PlayerLayout.cover);
    });

    test('设置成同一个值时不重复通知、不重复落盘', () async {
      final local = LocalLibraryRepository(store: FakeSecureStore());
      addTearDown(local.dispose);

      await local.setPlayerLayout(PlayerLayout.cover);
      var notified = 0;
      local.addListener(() => notified++);
      await local.setPlayerLayout(PlayerLayout.cover);
      expect(notified, 0);
    });

    test('持久化用的是稳定字符串（不是 index）', () async {
      final store = FakeSecureStore();
      final local = LocalLibraryRepository(store: store);
      addTearDown(local.dispose);

      await local.setPlayerLayout(PlayerLayout.cover);
      expect(store.prefs['playerLayout'], 'cover');
      await local.setPlayerLayout(PlayerLayout.stage);
      expect(store.prefs['playerLayout'], 'stage');
    });
  });

  group('PlayerLayout 枚举自身', () {
    test('fromStorage 认识合法值，未知/空值回落到 stage', () {
      expect(PlayerLayout.fromStorage('cover'), PlayerLayout.cover);
      expect(PlayerLayout.fromStorage('stage'), PlayerLayout.stage);
      expect(PlayerLayout.fromStorage(null), PlayerLayout.stage);
      expect(PlayerLayout.fromStorage(''), PlayerLayout.stage);
      expect(PlayerLayout.fromStorage('0'), PlayerLayout.stage,
          reason: '刻意不用 index —— 传 "0" 不应该是 cover');
      expect(PlayerLayout.fromStorage('大封面'), PlayerLayout.stage);
    });

    test('next 循环', () {
      expect(PlayerLayout.stage.next, PlayerLayout.cover);
      expect(PlayerLayout.cover.next, PlayerLayout.stage);
    });

    test('shortLabel 非空且互不相同', () {
      final labels =
          PlayerLayout.values.map((PlayerLayout v) => v.shortLabel).toSet();
      expect(labels.length, PlayerLayout.values.length);
      expect(labels.contains(''), isFalse);
    });
  });
}
