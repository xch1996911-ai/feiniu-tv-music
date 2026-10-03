import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import '../domain/pinyin_lexicon.dart';
import '../domain/pinyin_service.dart';
import '../domain/text_norm.dart';
import 'catalogue_store.dart';
import 'local_paths.dart';

/// 一条曲目的**缓存检索键**。
///
/// 只存「拼音音节表」而不存整串拼音，因为：
/// - [AlignedText.full] 就是 `syllables.join('')`，[AlignedText.initialsFlat]
///   是每个音节的首字符 —— 都不必单独存；
/// - 真正贵的是 `pinyin` 包的字表/词组表查询，音节表恰好是它的**最终产物**；
/// - 「原文」（汉字原位匹配用）可以由 `Track` 现算（见
///   [PinyinService.alignedSource]），不必存。
///
/// 于是缓存条目就是三个 `|` 分隔的音节串 + 一个变更指纹。
class CachedSearchDoc {
  const CachedSearchDoc({
    required this.guid,
    required this.fingerprint,
    required this.titleSyllables,
    required this.artistSyllables,
    required this.albumSyllables,
  });

  final String guid;

  /// 变更指纹：标题 / 歌手 / 专辑 / 更新时间任一变化都会变。
  ///
  /// 用它做**增量维护**：指纹没变的曲目直接复用上次的音节表，
  /// 只重算真正变了的那些（需求 §4「后台曲库增删改时增量维护」）。
  final String fingerprint;

  final String titleSyllables;
  final String artistSyllables;
  final String albumSyllables;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'g': guid,
        'f': fingerprint,
        't': titleSyllables,
        'a': artistSyllables,
        'b': albumSyllables,
      };

  static CachedSearchDoc? fromJson(Map<String, dynamic> json) {
    final String guid = (json['g'] as String?) ?? '';
    if (guid.isEmpty) return null;
    return CachedSearchDoc(
      guid: guid,
      fingerprint: (json['f'] as String?) ?? '',
      titleSyllables: (json['t'] as String?) ?? '',
      artistSyllables: (json['a'] as String?) ?? '',
      albumSyllables: (json['b'] as String?) ?? '',
    );
  }
}

/// 一份**拼音索引快照**（一次完整构建的产物）。
class SearchIndexSnapshot {
  final String identity;
  final DateTime? savedAt;
  final int trackCount;
  final Map<String, CachedSearchDoc> docs;

  const SearchIndexSnapshot({
    required this.identity,
    required this.savedAt,
    required this.trackCount,
    required this.docs,
  });
}

/// 拼音索引的本地持久化。
///
/// ## 为什么与曲库索引**分开**两个文件
///
/// 曲库索引（[CatalogueStore]）解决的是「曲目元数据 + 风格结论」的持久化；
/// 拼音索引解决的是「检索键」的持久化。两者的**失效条件完全不同**：
/// - 曲库索引只在曲库变（增删改）时重算；
/// - 拼音索引还会因为**归一化规则 / 拼音库 / 词组词典**的版本变化而整体失效。
///
/// 塞进一个文件会让「改一条词典 → 整份曲库索引作废」，
/// 或者反过来「曲库刷新 → 手工维护的检索键被覆盖」。
/// 分开之后各自原子替换，互不影响（需求 §4 的「设置索引版本，
/// 拼音规则变更时正确迁移或重建」正是这个意思）。
///
/// ## 隔离与降级
/// - 文件名含身份摘要 → 不同 NAS / 账户互不覆盖（需求 §4）；
/// - 任何异常（不存在 / 损坏 / 版本不符）**一律返回 null**，
///   由调用方重建；**绝不因为读缓存失败而清空当前可用的索引**。
class SearchIndexStore {
  SearchIndexStore({Directory? dir}) : _dirOverride = dir;

  final Directory? _dirOverride;

  /// 缓存结构版本。与 [TextNorm.version] / [PinyinService.version] /
  /// [PinyinLexicon.version] 一起构成版本指纹。
  static const int schema = 1;

  static const String _prefix = 'search_';
  static const String _suffix = '.json';

  /// 音节分隔符（`U+0001`）。JSON 里会被转义成 `\u0001`，
  /// 不会与任何真实文本冲突（[TextNorm._keep] 已丢弃所有控制字符）。
  static const String sylSeparator = '\u0001';

  Future<Directory?> _dir() async {
    final Directory? d = _dirOverride ?? await LocalPaths.dataDir();
    if (d == null) return null;
    try {
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (e) {
      Log.w('SEARCH_STORE 创建数据目录失败：$e');
      return null;
    }
    return d;
  }

  File _file(Directory dir, String identity) => File(
      '${dir.path}${Platform.pathSeparator}$_prefix'
      '${CatalogueStore.fileKey(identity)}$_suffix');

  /// 当前版本指纹（与落盘时比对，不一致即视为失效）。
  static Map<String, int> currentVersions() => <String, int>{
        'schema': schema,
        'norm': TextNorm.version,
        'pinyin': PinyinService.version,
        'lexicon': PinyinLexicon.version,
      };

  static bool _versionsMatch(Object? raw) {
    if (raw is! Map) return false;
    final Map<String, int> want = currentVersions();
    for (final MapEntry<String, int> e in want.entries) {
      final int got = (raw[e.key] as num?)?.toInt() ?? -1;
      if (got != e.value) {
        Log.w('SEARCH_STORE 版本不符：${e.key} 文件=$got 当前=${e.value} → 重建索引');
        return false;
      }
    }
    return true;
  }

  /// 读取缓存。不可用返回 null（**不是错误**，只是冷启动）。
  Future<SearchIndexSnapshot?> load(String identity) async {
    final Directory? dir = await _dir();
    if (dir == null) return null;
    final File file = _file(dir, identity);
    if (!file.existsSync()) {
      Log.i('SEARCH_STORE 无拼音索引缓存（首次运行或已换账户）');
      return null;
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) throw const FormatException('顶层不是对象');
      final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);

      if (!_versionsMatch(json['versions'])) return null;

      final String storedIdentity = (json['identity'] as String?) ?? '';
      if (storedIdentity != identity) {
        Log.w('SEARCH_STORE 身份不符（缓存属于其他 NAS/账户），已忽略');
        return null;
      }

      final Map<String, CachedSearchDoc> docs = <String, CachedSearchDoc>{};
      for (final Object? raw in (json['docs'] as List? ?? <Object?>[])) {
        if (raw is! Map) continue;
        final CachedSearchDoc? d =
            CachedSearchDoc.fromJson(Map<String, dynamic>.from(raw));
        if (d != null) docs[d.guid] = d;
      }
      Log.i('SEARCH_STORE 已恢复拼音索引缓存：${docs.length} 条检索键');
      return SearchIndexSnapshot(
        identity: identity,
        savedAt: _parseSeconds(json['savedAt']),
        trackCount: (json['trackCount'] as num?)?.toInt() ?? docs.length,
        docs: docs,
      );
    } catch (e, st) {
      Log.w('SEARCH_STORE 缓存读取失败（将重建）：$e', st);
      return null;
    }
  }

  /// 写入缓存（原子替换）。
  Future<void> save(SearchIndexSnapshot snap) async {
    final Directory? dir = await _dir();
    if (dir == null) return;
    final File file = _file(dir, snap.identity);
    final Map<String, dynamic> json = <String, dynamic>{
      'versions': currentVersions(),
      'identity': snap.identity,
      'savedAt': snap.savedAt?.millisecondsSinceEpoch ~/ 1000,
      'trackCount': snap.trackCount,
      'docs': <Map<String, dynamic>>[
        for (final CachedSearchDoc d in snap.docs.values) d.toJson(),
      ],
    };
    try {
      await _atomicWrite(file, jsonEncode(json));
      Log.i('SEARCH_STORE 拼音索引已落盘：${snap.docs.length} 条 · ${file.path}');
    } catch (e) {
      // 落盘失败只影响「下次启动要重算」，不该让本次搜索不可用。
      Log.w('SEARCH_STORE 缓存落盘失败（内存索引仍可用）：$e');
    }
  }

  /// 删除缓存（换 NAS / 登出时按需调用）。
  Future<void> clear(String identity) async {
    final Directory? dir = await _dir();
    if (dir == null) return;
    final File file = _file(dir, identity);
    try {
      if (file.existsSync()) await file.delete();
      Log.i('SEARCH_STORE 已删除拼音索引缓存 ${file.path}');
    } catch (e) {
      Log.w('SEARCH_STORE 删除缓存失败：$e');
    }
  }

  // ── 音节表编解码 ──────────────────────────────────────────

  /// 音节表 → 单串。
  static String encodeSyllables(List<String> syllables) =>
      syllables.join(sylSeparator);

  /// 单串 → 音节表。空串代表"没有音节"（调用方按字段为空处理）。
  static List<String> decodeSyllables(String raw) {
    if (raw.isEmpty) return const <String>[];
    return raw.split(sylSeparator);
  }

  static DateTime? _parseSeconds(Object? raw) {
    final int? n = (raw as num?)?.toInt();
    if (n == null || n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }

  static Future<void> _atomicWrite(File target, String content) async {
    final File tmp = File('${target.path}.tmp');
    final RandomAccessFile raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(content);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(target.path);
  }
}
