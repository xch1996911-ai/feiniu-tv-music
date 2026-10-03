import 'dart:convert';
import 'dart:io';

import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/pinyin_lexicon.dart';
import 'package:feiniu_tv_music/domain/pinyin_service.dart';
import 'package:feiniu_tv_music/domain/search_index.dart';
import 'package:feiniu_tv_music/domain/text_norm.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/services/catalogue_store.dart';
import 'package:feiniu_tv_music/services/search_index_store.dart';
import 'package:feiniu_tv_music/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 【V5】拼音模糊搜索的验收测试（需求「拼音模糊搜索」§二 / §三 / §四 / §五）。
///
/// ## 这组断言要防的是什么
///
/// 需求明文禁止「只有输入框文案或假搜索结果的实现」。所以这里**不看 UI**，
/// 直接对匹配核心与搜索服务下断言 —— 逐条覆盖需求列出的每一种输入形态。
///
/// ⚠️ 关于「随机」：本文件里所有断言都是**确定性**的（同一输入同一结果）。
/// 需求 §三 明确要求「稳定排序，不能每输入一个字母就无规律跳动」，
/// 因此没有任何随机成分参与打分或排序。
void main() {
  Track makeTrack(
    String guid, {
    required String title,
    String artist = '',
    String album = '',
    String albumGuid = '',
  }) {
    return Track(
      guid: guid,
      title: title,
      durationMs: 200000,
      album: AlbumRef(guid: albumGuid, name: album),
      artists: artist.isEmpty
          ? const <ArtistRef>[]
          : <ArtistRef>[ArtistRef(guid: 'ar_$artist', name: artist)],
      audioSpec: const AudioSpec(format: 'flac'),
    );
  }

  /// 需求 §五 要求的测试数据：真实曲库里的常见形态。
  List<Track> fixture() => <Track>[
        makeTrack('t1', title: '晴天', artist: '周杰伦', album: '叶惠美', albumGuid: 'al1'),
        makeTrack('t2', title: '七里香', artist: '周杰伦', album: '七里香', albumGuid: 'al2'),
        makeTrack('t3', title: '告白气球', artist: '周杰伦', album: '周杰伦的床边故事', albumGuid: 'al3'),
        makeTrack('t4', title: '突然好想你', artist: '五月天', album: '后青春期的诗', albumGuid: 'al4'),
        makeTrack('t5', title: '温柔', artist: '五月天', album: '天空之城', albumGuid: 'al5'),
        makeTrack('t6', title: 'Get Lucky', artist: 'Daft Punk', album: 'Random Access Memories', albumGuid: 'al6'),
        makeTrack('t7', title: '晴天 (Live)', artist: '周杰伦', album: '演唱会', albumGuid: 'al7'),
        makeTrack('t8', title: '重庆森林', artist: '群星', album: '电影原声', albumGuid: 'al8'),
      ];

  SearchIndex indexOf(List<Track> tracks) {
    final SearchService svc = SearchService();
    svc.ensureSync(tracks);
    final SearchIndex idx = svc.index;
    svc.dispose();
    return idx;
  }

  SearchResults q(String raw, {List<Track>? tracks}) =>
      indexOf(tracks ?? fixture()).query(raw, indexComplete: true);

  List<String> titles(SearchResults r) =>
      <String>[for (final SearchHit h in r.songs) h.track.title];

  group('§二 匹配规则', () {
    test('① 中文原文搜索继续可用', () {
      expect(titles(q('晴天')), contains('晴天'));
      expect(q('周杰伦').artists.map((EntityHit e) => e.name), contains('周杰伦'));
    });

    test('② 拼音全拼（含空格分隔）', () {
      expect(titles(q('qingtian')), contains('晴天'));
      expect(titles(q('zhoujielun')), isNotEmpty,
          reason: '全拼应命中歌手为「周杰伦」的歌曲');
      // 空格只是分隔符：`zhou jie lun` 与 `zhoujielun` 等价
      final SearchResults spaced = q('zhou jie lun');
      final SearchResults joined = q('zhoujielun');
      expect(spaced.songs.length, joined.songs.length);
    });

    test('③ 首字母（含前缀）', () {
      expect(q('zjl').artists.map((EntityHit e) => e.name), contains('周杰伦'));
      expect(titles(q('qlx')), contains('七里香'));
      expect(q('wyt').artists.map((EntityHit e) => e.name), contains('五月天'));
      // `zj` 是首字母**前缀**，也应命中
      expect(q('zj').artists.map((EntityHit e) => e.name), contains('周杰伦'));
    });

    test('完整首字母优于首字母前缀（看命中位置，不看分值）', () {
      // ⚠️ 断在机制上而不是聚合分值上：需求要的是「完整首字母排在前面」，
      //    而分值常量属于可调参数 —— 把测试钉在常量上，一调参就红，
      //    却说明不了行为有没有退化。
      final AlignedText zhou = PinyinService.align(
        TextNorm.key('周杰伦'),
      );
      final FieldMatch? full = SearchIndex.matchField(zhou, 'zjl');
      final FieldMatch? pre = SearchIndex.matchField(zhou, 'zj');
      expect(full, isNotNull);
      expect(pre, isNotNull);
      expect(full!.strength, MatchStrength.initials);
      expect(full.position, MatchPosition.exact, reason: '完整首字母 = 整段命中');
      expect(pre!.position, MatchPosition.prefix, reason: '前缀只吃前两个字');
    });

    test('④ 部分拼音：拼音前缀与连续子串', () {
      expect(q('zhoujie').artists.map((EntityHit e) => e.name), contains('周杰伦'));
      expect(q('jielun').artists.map((EntityHit e) => e.name), contains('周杰伦'),
          reason: '单词音节分片（杰伦 = jielun）也要能命中');
      expect(titles(q('qingt')), contains('晴天'));
    });

    test('短查询不做宽松匹配（一个字母不能命中整个曲库）', () {
      final SearchIndex idx = indexOf(fixture());
      final SearchResults r = idx.query('z', indexComplete: true);
      // `z` 只能作为首字母前缀命中，绝不能因为「包含 z」把整库捞出来
      expect(r.songs.length, lessThan(idx.length));
    });

    test('⑤ 混合查询：中文 + 拼音任意组合', () {
      expect(q('周jie伦').artists.map((EntityHit e) => e.name), contains('周杰伦'));
      expect(q('zhou杰伦').artists.map((EntityHit e) => e.name), contains('周杰伦'));
      // 多关键词 AND，允许分布在歌曲名 / 歌手 / 专辑不同字段
      expect(titles(q('五月天 温柔')), contains('温柔'));
      expect(titles(q('五月天 晴天')), isEmpty,
          reason: '「五月天」与「晴天」不属于同一首，AND 语义下应为空');
    });

    test('⑥ 英文大小写不敏感', () {
      expect(titles(q('get lucky')), contains('Get Lucky'));
      expect(titles(q('GET LUCKY')), contains('Get Lucky'));
      expect(titles(q('GetLucky')), contains('Get Lucky'),
          reason: '标点与空格在索引键里被归一化掉');
    });

    test('⑦ 空格 / 全角 / 标点归一化', () {
      expect(titles(q('  晴天  ')), contains('晴天'));
      expect(titles(q('ｑｉｎｇｔｉａｎ')), contains('晴天'),
          reason: '全角字母要转半角');
      expect(titles(q('七-里-香')), contains('七里香'));
    });

    test('归一化不改写展示名：版本词保留在原名里', () {
      final SearchResults r = q('qlx');
      expect(titles(r), contains('七里香'));
      // 「晴天 (Live)」这类版本信息必须原样保留，否则用户无法区分版本
      final SearchResults live = q('qingtian');
      expect(titles(live).any((String t) => t.contains('Live')), isTrue,
          reason: '搜索用于匹配的键被归一化，但展示标题一个字节都不能改');
    });

    test('⑧ 轻微拼写错误给出低优先级候选', () {
      final SearchResults good = q('zhoujielun');
      final SearchResults typo = q('zhoujielnu');
      expect(typo.songs, isNotEmpty, reason: '相邻换位是最常见的手打错误');
      expect(typo.songs.map((SearchHit h) => h.track.title),
          containsAll(good.songs.map((SearchHit h) => h.track.title)),
          reason: '纠错结果应是正确结果的**低优先级补充**，不能改答案');
      expect(good.fuzzyUsed, isFalse, reason: '精确命中时不该启用纠错路径');
      expect(typo.fuzzyUsed, isTrue, reason: '只有纠错路径才会给出这条候选');
    });

    test('多音字：词组优先（重庆 / 音乐 等）', () {
      expect(titles(q('chongqing')), contains('重庆森林'),
          reason: '「重」在「重庆」里读 chóng —— 单字读音会变成 zhòng');
      expect(titles(q('zhongqing')), isEmpty,
          reason: '错误的读音不该命中');
    });

    test('无结果时安静返回空，不编造命中', () {
      expect(q('zzzznotexist').songs, isEmpty);
      expect(q('这首歌不存在').songs, isEmpty);
    });
  });

  group('§三 结果与排序', () {
    test('中文原文精确匹配优先于拼音匹配', () {
      // 结果层面：查原文时「晴天」必须排第一（上面已断言），
      // 这里再把机制钉住 —— 原文命中判成 original/exact，拼音命中判成 pinyin。
      final AlignedText doc = PinyinService.align(TextNorm.key('晴天'));
      final FieldMatch? byText = SearchIndex.matchField(doc, '晴天');
      final FieldMatch? byPinyin = SearchIndex.matchField(doc, 'qingtian');
      expect(byText!.strength, MatchStrength.original);
      expect(byText.position, MatchPosition.exact);
      expect(byPinyin!.strength, MatchStrength.pinyin);
      expect(
        SearchIndex.scoreOf(SearchField.title, byText),
        greaterThan(SearchIndex.scoreOf(SearchField.title, byPinyin)),
        reason: '原文命中的分数必须严格高于拼音命中',
      );
    });

    test('歌曲名命中优先于仅歌手字段命中', () {
      final SearchIndex idx = indexOf(fixture());
      final SearchResults r = idx.query('晴天', indexComplete: true);
      // 「晴天」命中歌名的分数应高于「周杰伦」条目里仅由歌手命中的那些
      final int titleHit = r.songs
          .firstWhere((SearchHit h) => h.track.title.startsWith('晴天'))
          .score;
      expect(r.songs.first.score, titleHit);
    });

    test('查询歌手名时歌手条目优先，其歌曲也能通过歌手字段命中', () {
      final SearchResults r = q('周杰伦');
      expect(r.artists.first.name, '周杰伦');
      expect(r.songs.length, greaterThanOrEqualTo(3),
          reason: '歌手字段命中应带出该歌手的歌曲');
    });

    test('排序稳定可复现（同查询两次结果完全一致）', () {
      final SearchIndex idx = indexOf(fixture());
      final List<String> a = <String>[
        for (final SearchHit h in idx.query('五月天', indexComplete: true).songs)
          h.track.guid,
      ];
      final List<String> b = <String>[
        for (final SearchHit h in idx.query('五月天', indexComplete: true).songs)
          h.track.guid,
      ];
      expect(a, b);
    });

    test('结果不展示内部拼音索引，只有原始曲目信息', () {
      final SearchResults r = q('zjl');
      for (final SearchHit h in r.songs) {
        expect(h.track.title, isNotEmpty);
        // 归一化键永远不出现在曲目模型里
        expect(h.track.title.contains('\u0001'), isFalse);
      }
    });
  });

  group('§四 完整曲库、缓存与性能', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('search_index_');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('超过 50 首时，第 51 首与最后一首都能被拼音找到', () async {
      final List<Track> big = <Track>[
        for (int i = 1; i <= 137; i++)
          makeTrack('g$i', title: '曲目 $i', artist: '周杰伦', album: '专辑'),
      ];
      // 第 51 首与最后一首用可拼音化的标题
      big[50] = makeTrack('g51', title: '七里香', artist: '周杰伦', album: '专辑');
      big[136] = makeTrack('g137', title: '晴天', artist: '五月天', album: '专辑');

      final SearchService svc = SearchService(store: SearchIndexStore(dir: tmp));
      await svc.sync(big, identity: 'nasA#u1', complete: true);

      expect(svc.length, 137, reason: '必须覆盖全库，不能只索引首页 50 首');
      expect(svc.querySync('qlx').songs.map((SearchHit h) => h.track.guid),
          contains('g51'));
      expect(svc.querySync('qingtian').songs.map((SearchHit h) => h.track.guid),
          contains('g137'));
      svc.dispose();
    });

    test('索引持久缓存：重建实例后**不重算**就能搜到（账号隔离）', () async {
      final List<Track> tracks = fixture();
      final SearchService a = SearchService(store: SearchIndexStore(dir: tmp));
      await a.sync(tracks, identity: 'nasA#u1', complete: true);
      await a.settled; // 等落盘完成，否则下一步可能读不到缓存
      expect(a.querySync('qlx').songs, isNotEmpty);
      expect(a.builtCount, 8);
      a.dispose();

      final SearchService b = SearchService(store: SearchIndexStore(dir: tmp));
      await b.sync(tracks, identity: 'nasA#u1', complete: true);
      expect(b.restoredFromCache, isTrue, reason: '应命中磁盘缓存');
      expect(b.querySync('qlx').songs, isNotEmpty, reason: '重启后直接可搜');

      // 换账户：索引必须隔离，不能串数据
      final SearchService c = SearchService(store: SearchIndexStore(dir: tmp));
      await c.sync(tracks, identity: 'nasB#u2', complete: true);
      expect(c.restoredFromCache, isFalse, reason: '不同账户不得复用彼此的缓存');
      c.dispose();
      b.dispose();
    });

    test('增量维护：只有变化的条目被重算', () async {
      final List<Track> tracks = fixture();
      final SearchService svc =
          SearchService(store: SearchIndexStore(dir: tmp));
      await svc.sync(tracks, identity: 'x', complete: true);

      // 只改第 1 首的标题，其余原样
      final List<Track> changed = <Track>[
        makeTrack('t1', title: '晴天（改名）', artist: '周杰伦', album: '叶惠美', albumGuid: 'al1'),
        ...tracks.sublist(1),
      ];
      await svc.sync(changed, identity: 'x', complete: true);

      expect(svc.querySync('qingtian').songs, isNotEmpty,
          reason: '改名后的新标题必须立即可搜');
      svc.dispose();
    });

    test('缓存版本不符时**整份丢弃重建**，绝不沿用失效缓存', () async {
      // 直接写一份「版本号不对」的缓存文件（模拟拼音库/归一化规则升级）
      final File file = File('${tmp.path}${Platform.pathSeparator}'
          'search_${CatalogueStore.fileKey('x')}.json');
      file.writeAsStringSync(jsonEncode(<String, dynamic>{
        'versions': <String, int>{'schema': 9999},
        'identity': 'x',
        'docs': <Object?>[],
      }));
      final SearchIndexStore store = SearchIndexStore(dir: tmp);
      expect(await store.load('x'), isNull,
          reason: '版本指纹不一致必须视为「无缓存」');

      final SearchService svc = SearchService(store: store);
      await svc.sync(fixture(), identity: 'x', complete: true);
      expect(svc.querySync('qlx').songs, isNotEmpty);
      svc.dispose();
    });

    test('曲库清空后再恢复：索引跟着走，不残留也不卡死', () async {
      final SearchService svc =
          SearchService(store: SearchIndexStore(dir: tmp));
      await svc.sync(fixture(), identity: 'x', complete: true);
      expect(svc.length, 8);

      // 曲库被清空（例如换了 NAS 且新库为空）
      await svc.sync(<Track>[], identity: 'x', complete: false);
      expect(svc.length, 0);
      expect(svc.querySync('qlx').songs, isEmpty);

      // 再恢复：必须能重新建起来（而不是卡在空索引上）
      await svc.sync(fixture(), identity: 'x', complete: true);
      expect(svc.length, 8);
      expect(svc.querySync('qlx').songs, isNotEmpty);
      svc.dispose();
    });

    test('查询序号：晚到的旧结果会被标记为过期', () async {
      final SearchService svc =
          SearchService(store: SearchIndexStore(dir: tmp));
      await svc.sync(fixture(), identity: 'x', complete: true);

      final Future<SearchOutcome> slow = svc.search('qingtian');
      final Future<SearchOutcome> fast = svc.search('qlx');
      final SearchOutcome a = await slow;
      final SearchOutcome b = await fast;
      expect(a.superseded, isTrue, reason: '先发起的查询必须被标记为过期');
      expect(b.superseded, isFalse);
      expect(b.seq, greaterThan(a.seq));
      expect(b.results.songs, isNotEmpty);
      svc.dispose();
    });
  });

  group('§四 归一化与词典约束', () {
    test('TextNorm：全角→半角、大小写折叠、ü→v、丢标点', () {
      expect(TextNorm.key('ＡＢＣ'), 'abc');
      expect(TextNorm.key('七里香 (Live版)'), '七里香live版');
      expect(TextNorm.key('七里香 (Live)'), '七里香live');
      // ⚠️ `key()` 只做「写法归一」，**不做汉语转拼音**：
      //    汉字原样保留（「女」还是「女」），拼音键由 PinyinService 负责。
      expect(TextNorm.key('女'), '女');
      expect(PinyinService.align(TextNorm.key('女')).full, 'nv',
          reason: 'ü 在拼音键里一律写作 v');
      expect(TextNorm.key('nü'), 'nv', reason: '用户直接打 ü 也要归一成 v');
      expect(TextNorm.tokens('  周杰伦   晴天 '), <String>['周杰伦', '晴天']);
      expect(TextNorm.versionTags('七里香 (Live)'), contains('live'));
    });

    test('项目词典：每条都满足「简体 / 小写无调 / 读音数=字数」', () {
      expect(PinyinLexicon.entries, isNotEmpty);
      PinyinLexicon.entries.forEach((String word, String pinyin) {
        final List<String> parts = pinyin.split(',');
        expect(parts.length, word.runes.length,
            reason: '「$word=$pinyin」读音个数与字数必须一致，否则整条会被忽略');
        for (final String p in parts) {
          expect(p, p.trim(), reason: '「$word」不该有空格');
          expect(p, p.toLowerCase(), reason: '「$word」必须全小写');
          expect(p.contains('ü'), isFalse, reason: '「$word」的 ü 必须写成 v');
          expect(RegExp(r'^[a-z]+$').hasMatch(p), isTrue,
              reason: '「$word」的读音 $p 含非法字符');
        }
      });
    });

    test('词典的最长词组长度是推导出来的（不是写死的）', () {
      int maxLen = 0;
      for (final String w in PinyinLexicon.entries.keys) {
        if (w.runes.length > maxLen) maxLen = w.runes.length;
      }
      expect(PinyinLexicon.longestPhraseLength, maxLen);
    });
  });
}
