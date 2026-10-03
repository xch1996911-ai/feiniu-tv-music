import 'dart:io';

import 'package:feiniu_tv_music/core/exceptions.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/services/catalogue_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_secure_store.dart';

/// 【V5】全曲库索引的验收测试（需求 §三-A / §三-B）。
///
/// ## 为什么必须单独锁这件事
///
/// 实机现象是「**刚启动时歌手/专辑不全，点开音乐库并滚动到全部音乐后，
/// 分类就恢复正常**」。根因在 `LibraryRepository`：概览读的是
/// `library.tracks`，而它只包含「用户滚动过的那几页」——
/// 不点音乐库，就永远只有首批 50 首参与分类，而首页卡片显示的
/// 服务端 `total` 是 2796，两个口径天然对不上。
///
/// 所以本文件用 **137 首 / 每页 50 首** 的场景锁死四件事：
/// 1. 索引**自己**拉完全部页，不依赖任何页面（A）；
/// 2. 第 51 / 101 / 137 首出现在正确的分组里（B）；
/// 3. 失败、重启、换账户时统计口径**不会退化成「只算第一批」**（C–G）；
/// 4. 半成品不覆盖完整索引（E）。
void main() {
  /// 造 [count] 首：每 10 首一个歌手、每 7 首一张专辑，方便断言边界。
  /// 曲目 guid = `g1..gN`，歌手 guid = `ar0..ar13`，专辑 guid = `al0..al19`。
  List<Track> makeCatalogue(int count) {
    return <Track>[
      for (int i = 1; i <= count; i++)
        Track(
          guid: 'g$i',
          title: '曲目 $i',
          durationMs: 180000,
          createdAt: DateTime.fromMillisecondsSinceEpoch(i * 1000),
          album: AlbumRef(guid: 'al${i ~/ 7}', name: '专辑 ${i ~/ 7}'),
          artists: <ArtistRef>[
            ArtistRef(guid: 'ar${i ~/ 10}', name: '歌手 ${i ~/ 10}'),
          ],
          audioSpec: const AudioSpec(format: 'flac'),
        ),
    ];
  }

  late FakeMusicRepository music;
  late Directory tmp;
  late CatalogueStore store;

  setUp(() async {
    music = FakeMusicRepository();
    tmp = await Directory.systemTemp.createTemp('catalogue_test_');
    store = CatalogueStore(dir: tmp);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('§三-A 全曲库分页索引', () {
    test('A 137 首 / 每页 50：startSync 自己把三页拉完，不依赖任何页面', () async {
      music.catalogue = makeCatalogue(137);
      final library = LibraryRepository(music, store: store);

      await library.startSync('test@nas#user');

      expect(library.tracks.length, 137, reason: '必须索引到全库 137 首');
      expect(library.total, 137, reason: '总数取自服务端 total');
      expect(library.indexComplete, isTrue, reason: '三页拉完且数量对齐 → 完整');
      expect(music.trackPageRequests, <String>['1/50', '2/50', '3/50'],
          reason: '按 page/size 逐页取；不能靠把 pageSize 调大');
      library.dispose();
    });

    test('B 第 51 / 101 / 137 首都进入正确的歌手与专辑分组', () async {
      music.catalogue = makeCatalogue(137);
      final library = LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');

      final List<LibraryOverview> artists =
          LocalLibraryRepository.artistOverviews(library.tracks);
      final List<LibraryOverview> albums =
          LocalLibraryRepository.albumOverviews(library.tracks);

      LibraryOverview? find(List<LibraryOverview> groups, String title) {
        for (final LibraryOverview o in groups) {
          if (o.title == title) return o;
        }
        return null;
      }

      void expectIn(
        int n,
        String groupTitle,
        List<LibraryOverview> groups,
        String kind,
      ) {
        final LibraryOverview? g = find(groups, groupTitle);
        expect(g, isNotNull, reason: '$kind「$groupTitle」应当存在');
        expect(g!.tracks.any((Track t) => t.guid == 'g$n'), isTrue,
            reason: '第 $n 首应出现在 $kind「$groupTitle」里 —— '
                '这正是「只对前 50 首分组」时会失败的断言');
      }

      expectIn(51, '歌手 5', artists, '歌手');
      expectIn(101, '歌手 10', artists, '歌手');
      expectIn(137, '歌手 13', artists, '歌手');
      expectIn(51, '专辑 7', albums, '专辑');
      expectIn(101, '专辑 14', albums, '专辑');
      expectIn(137, '专辑 19', albums, '专辑');

      expect(artists.length, 14, reason: '0..13 共 14 位歌手');
      library.dispose();
    });

    test('C 服务端返回重复项时按 guid 去重，统计不虚高', () async {
      // 第 2 页故意与第 1 页重叠 20 首
      music.catalogue = <Track>[
        ...makeCatalogue(50),
        ...makeCatalogue(70).sublist(30), // g31..g70
      ];
      final library = LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');

      final Set<String> guids = library.tracks.map((Track t) => t.guid).toSet();
      expect(guids.length, library.tracks.length, reason: '不得有重复 guid');
      expect(library.tracks.length, 70);
      library.dispose();
    });

    test('D 某页失败时保留已取得的数据，且不谎报「已整理完成」', () async {
      music.catalogue = makeCatalogue(137);
      final library = LibraryRepository(music, store: store);
      await library.loadFirst();
      expect(library.tracks.length, 50);

      music.failNextTrackRequest = const AppError('网络不可达');
      final bool ok = await library.loadMore();

      expect(ok, isFalse);
      expect(library.tracks.length, 50, reason: '已取得的数据必须保留（可重试/续传）');
      expect(library.indexComplete, isFalse, reason: '绝不能标记为完整');
      expect(library.error, isNotNull);
      library.dispose();
    });

    test('E 半成品不覆盖上一次的完整索引', () async {
      music.catalogue = makeCatalogue(137);
      final library = LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');
      expect(library.indexComplete, isTrue);
      final int completeCount = library.tracks.length;

      // 第二次整理：第 1 页就失败
      music.failNextTrackRequest = const AppError('网络不可达');
      await library.rebuildIndex();

      expect(library.tracks.length, completeCount,
          reason: '整理失败必须保留上一份完整索引，而不是退化成半成品');
      expect(library.indexComplete, isTrue,
          reason: '手上这份索引本身是完整的；只是「本次在线核对」没做完');
      library.dispose();
    });

    test('F 重启后直接读本地索引即可拿到全部分类', () async {
      music.catalogue = makeCatalogue(137);
      final LibraryRepository first = LibraryRepository(music, store: store);
      await first.startSync('test@nas#user');
      first.dispose();

      // 新实例：离线（任何在线请求都会失败）
      final FakeMusicRepository offline = FakeMusicRepository();
      offline.failNextTrackRequest = const AppError('断网');
      final LibraryRepository second =
          LibraryRepository(offline, store: store);
      await second.startSync('test@nas#user');

      expect(second.tracks.length, 137,
          reason: '缓存里必须是**完整索引**，而不是页面上显示过的那几十首');
      expect(second.indexComplete, isTrue);
      second.dispose();
    });

    test('G 索引按身份分文件：切换账户不串数据，也不互相覆盖', () async {
      music.catalogue = makeCatalogue(137);
      final LibraryRepository a1 = LibraryRepository(music, store: store);
      await a1.startSync('nasA@host-a#user-1');
      expect(a1.tracks.length, 137);

      // 同一实例切到账户 B：内存里不能残留 A 的曲目
      music.catalogue = makeCatalogue(12);
      await a1.startSync('nasB@host-b#user-2');
      expect(a1.tracks.length, 12, reason: '切换身份后不能残留上一账户的曲目');
      a1.dispose();

      // 关键：账户 B 的整理**不能覆盖**账户 A 的索引文件。
      // 用一个「离线」的新实例读回账户 A —— 只能来自磁盘缓存。
      final FakeMusicRepository offline = FakeMusicRepository();
      offline.failNextTrackRequest = const AppError('断网');
      final LibraryRepository a2 = LibraryRepository(offline, store: store);
      await a2.startSync('nasA@host-a#user-1');
      expect(a2.tracks.length, 137,
          reason: '账户 A 的索引文件必须仍然存在且未被账户 B 覆盖');
      a2.dispose();
    });

    test('H 曲库新增曲目后，再次整理能增量核对出来', () async {
      music.catalogue = makeCatalogue(60);
      final library = LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');
      expect(library.tracks.length, 60);

      music.catalogue = makeCatalogue(70);
      await library.rebuildIndex();
      expect(library.tracks.length, 70, reason: '新增的 10 首必须进入索引');
      library.dispose();
    });

    test('I 索引进度文案同时给出「已索引」与「全库总数」，不混为一谈', () async {
      music.catalogue = makeCatalogue(137);
      final library = LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');
      expect(library.tracks.length, 137);
      expect(library.syncStatus.indexed, 137);
      expect(library.syncStatus.serverTotal, 137);
      expect(library.syncStatus.complete, isTrue);
      library.dispose();
    });
  });

  group('§三-B 索引持久化的健壮性', () {
    test('J 损坏的索引文件按「无缓存」处理，不阻断启动', () async {
      final LibraryRepository library =
          LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');
      library.dispose();

      // 把索引文件写坏
      final List<File> files = tmp
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('catalogue_'))
          .toList();
      expect(files, isNotEmpty, reason: '应当已经落盘了索引文件');
      files.first.writeAsStringSync('{ 这不是合法 JSON');

      music.catalogue = makeCatalogue(60);
      final LibraryRepository second = LibraryRepository(music, store: store);
      await second.startSync('test@nas#user');
      expect(second.tracks.length, 60,
          reason: '缓存坏了就重新扫，而不是抛异常或卡住');
      second.dispose();
    });

    test('K 手动风格覆盖与索引分离，重建索引不会清掉用户确认', () async {
      music.catalogue = makeCatalogue(20);
      final LocalLibraryRepository local = LocalLibraryRepository(
        store: FakeSecureStore(),
        catalogue: store,
      );
      await local.setTrackGenres('g1', <String>['摇滚']);

      final LibraryRepository library =
          LibraryRepository(music, store: store);
      await library.startSync('test@nas#user');
      await library.rebuildIndex();

      final LocalLibraryRepository reopened = LocalLibraryRepository(
        store: FakeSecureStore(),
        catalogue: store,
      );
      await reopened.restore();
      expect(reopened.trackedGenres('g1'), <String>['摇滚'],
          reason: '重建索引整份替换 catalogue_*.json，但绝不碰 genre_overrides.json');
      library.dispose();
      local.dispose();
      reopened.dispose();
    });
  });
}
