import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import '../domain/genre.dart';
import '../domain/json_util.dart';
import '../domain/track.dart';
import 'local_paths.dart';

/// 曲库索引快照 —— **一次完整扫描的产物**。
///
/// 需求 §三-B.3 要求持久化的是「完整索引及其统计/分类依赖数据」，
/// 而不只是页面上显示的那 50 首或几个汇总数字。因此这里存的是：
/// - [tracks]：**全库**曲目元数据（服务端 JSON 形态，可原样反序列化）；
/// - [genres]：风格归纳结果（含**来源与置信度**，需求 §三.4/§三.6）；
/// - [ruleVersion]：产出该结果时的归纳规则版本（规则一变即需重算）；
/// - [complete]：本次扫描是否**确认拉完了全部页**。
///   ⚠️ 半成品（分页中途失败）不得覆盖上一次的完整索引 ——
///   见 `LibraryRepository` 里的写入门槛。
/// - [identity]：NAS + 账户身份，用于多账户隔离（需求 §三-A.9）。
class CatalogueSnapshot {
  /// 生成这份快照时的 schema 版本。
  ///
  /// 与 `CatalogueStore.schemaVersion` 不一致的快照**直接丢弃**：
  /// 宁可重新扫一遍，也不要读半懂不懂的旧结构。
  static const int schema = 2;

  final String identity;
  final DateTime? savedAt;

  /// 是否**确认**拉完全部页（`hasMore == false`）。
  final bool complete;

  /// 服务端报告的曲目总数（`track/list` 的 `total`）。
  ///
  /// 与 [tracks] 的长度一起构成「分页完成证据」：
  /// `tracks.length == serverTotal` 才说明真的拉全了。
  final int serverTotal;

  final List<Track> tracks;

  /// 曲目标识 → 风格归属。
  final Map<String, List<GenreAssignment>> genres;

  /// 产出 [genres] 时的规则版本。
  final int ruleVersion;

  const CatalogueSnapshot({
    required this.identity,
    required this.savedAt,
    required this.complete,
    required this.serverTotal,
    required this.tracks,
    required this.genres,
    required this.ruleVersion,
  });
}

/// 曲库索引的本地持久化（私有目录下的普通 JSON 文件）。
///
/// ## 为什么是一个 JSON 文件而不是数据库
///
/// 规模是**几千条**（实测样本 2796 首），单次写入约 2~4 MB。
/// 这个量级下：
/// - 一次全量写 + 原子替换，比引入 sqlite 依赖**更简单也更可靠**
///   （需求 §三-B.4 明确「不要求为了本提示词盲目增加数据库依赖」）；
/// - 索引本来就是「快照」语义（拉完一次就整份换掉），不是需要随机读写的表。
///
/// 若将来曲库规模上一个数量级（十万级），这里应换成 append-only + 定期压缩，
/// [CatalogueStore] 的接口不需要变。
///
/// ## 原子性
/// 先写 `.tmp`，`flush` 后 `rename` 覆盖目标文件 —— 同目录内的 rename 在
/// Android 上是原子操作。这样**断电/被杀进程**也不会留下半个 JSON：
/// 要么是旧索引，要么是新索引，不存在「解析到一半」的状态。
///
/// ## 两个文件，互不影响
/// - `catalogue_<identity>.json`：索引本身。**重建索引会整份替换它**；
/// - `genre_overrides.json`：用户手动确认的风格。**永不**被重建索引触碰
///   （需求 §三-B.7：刷新/重建不能无故重置用户记忆）。
class CatalogueStore {
  CatalogueStore({Directory? dir}) : _dirOverride = dir;

  final Directory? _dirOverride;

  static const String _indexPrefix = 'catalogue_';
  static const String _indexSuffix = '.json';

  /// 用户手动风格覆盖的文件名（与索引分离，见类文档）。
  static const String overridesFile = 'genre_overrides.json';

  Future<Directory?> _dir() async {
    final Directory? d = _dirOverride ?? await LocalPaths.dataDir();
    if (d == null) return null;
    try {
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (e) {
      Log.w('CATALOGUE_STORE 创建数据目录失败：$e');
      return null;
    }
    return d;
  }

  /// 用身份串生成文件名。
  ///
  /// ⚠️ 身份串里含主机地址与账户标识，**不能直接当文件名**（含 `:` `/` 等
  /// 非法字符）。这里做一次稳定摘要：只保留字母数字，再截取长度上限。
  /// 它不承担安全职责（文件本就在应用私有目录里），只保证「同一身份稳定映射
  /// 到同一文件、不同身份不互相覆盖」。
  static String fileKey(String identity) {
    final StringBuffer buf = StringBuffer();
    for (final int r in identity.runes) {
      final String ch = String.fromCharCode(r);
      if (RegExp(r'[0-9A-Za-z]').hasMatch(ch)) {
        buf.write(ch);
      } else {
        buf.write('_');
      }
    }
    final String s = buf.toString();
    return s.length <= 96 ? s : s.substring(s.length - 96);
  }

  File _indexFile(Directory dir, String identity) => File(
      '${dir.path}${Platform.pathSeparator}$_indexPrefix${fileKey(identity)}$_indexSuffix');

  File _overridesFile(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$overridesFile');

  /// 读取索引。任何异常（文件不存在 / JSON 损坏 / schema 不符 / 身份不符）
  /// 一律返回 null 并记日志 —— **缓存不可用只是降级，不是错误**。
  Future<CatalogueSnapshot?> load(String identity) async {
    final Directory? dir = await _dir();
    if (dir == null) return null;
    final File file = _indexFile(dir, identity);
    if (!file.existsSync()) {
      Log.i('CATALOGUE_STORE 无本地索引（首次运行或已换账户）');
      return null;
    }
    try {
      final String text = await file.readAsString();
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('顶层不是对象');
      final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);

      final int schema = (json['schema'] as num?)?.toInt() ?? 0;
      if (schema != CatalogueSnapshot.schema) {
        Log.w('CATALOGUE_STORE schema 不符（文件 $schema ≠ 当前 '
            '${CatalogueSnapshot.schema}），丢弃旧索引');
        return null;
      }
      final String storedIdentity = (json['identity'] as String?) ?? '';
      if (storedIdentity != identity) {
        Log.w('CATALOGUE_STORE 身份不符（索引属于其他 NAS/账户），已忽略');
        return null;
      }

      final List<Track> tracks = <Track>[
        for (final Object? raw in (json['tracks'] as List? ?? <Object?>[]))
          if (raw is Map) Track.fromJson(Map<String, dynamic>.from(raw)),
      ];
      final Map<String, List<GenreAssignment>> genres =
          decodeAssignments(json['genres']);

      final CatalogueSnapshot snap = CatalogueSnapshot(
        identity: identity,
        savedAt: _parseSeconds(json['savedAt']),
        complete: json['complete'] == true,
        serverTotal: (json['serverTotal'] as num?)?.toInt() ?? tracks.length,
        tracks: tracks,
        genres: genres,
        ruleVersion: (json['ruleVersion'] as num?)?.toInt() ?? 0,
      );
      Log.i('CATALOGUE_STORE 已恢复索引：${tracks.length} 首 · '
          '服务端总数 ${snap.serverTotal} · 完整=${snap.complete} · '
          '风格归属 ${genres.length} 条 · 规则版本 ${snap.ruleVersion}');
      return snap;
    } catch (e, st) {
      // 损坏的缓存不该阻断启动：下一次成功扫描会整份覆盖它。
      //
      // ⚠️ `Log.w` 只接受一个参数（见 `lib/core/log.dart`）；需要带堆栈时
      //    必须用 `Log.e(message, error, stackTrace)`。
      Log.e('CATALOGUE_STORE 索引读取失败（按无缓存继续）', e, st);
      return null;
    }
  }

  /// 写入索引（原子替换）。
  Future<void> save(CatalogueSnapshot snap) async {
    final Directory? dir = await _dir();
    if (dir == null) return;
    final File file = _indexFile(dir, snap.identity);
    final Map<String, dynamic> json = <String, dynamic>{
      'schema': CatalogueSnapshot.schema,
      'identity': snap.identity,
      'savedAt': unixSecondsOf(snap.savedAt),
      'complete': snap.complete,
      'serverTotal': snap.serverTotal,
      'ruleVersion': snap.ruleVersion,
      'tracks': <Map<String, dynamic>>[
        for (final Track t in snap.tracks) t.toJson(),
      ],
      'genres': encodeAssignments(snap.genres),
    };
    await _atomicWrite(file, jsonEncode(json));
    Log.i('CATALOGUE_STORE 索引已落盘：${snap.tracks.length} 首 · '
        '完整=${snap.complete} · ${file.path}');
  }

  /// 删除索引（换 NAS / 登出时按需调用）。
  Future<void> clear(String identity) async {
    final Directory? dir = await _dir();
    if (dir == null) return;
    final File file = _indexFile(dir, identity);
    try {
      if (file.existsSync()) await file.delete();
      Log.i('CATALOGUE_STORE 已删除索引 ${file.path}');
    } catch (e) {
      Log.w('CATALOGUE_STORE 删除索引失败：$e');
    }
  }

  // ── 手动风格覆盖（与索引分离）────────────────────────────

  /// 读取用户手动的风格归属。
  Future<Map<String, List<String>>> loadOverrides() async {
    final Directory? dir = await _dir();
    if (dir == null) return <String, List<String>>{};
    final File file = _overridesFile(dir);
    if (!file.existsSync()) return <String, List<String>>{};
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return <String, List<String>>{};
      final Map<String, List<String>> out = <String, List<String>>{};
      decoded.forEach((Object? k, Object? v) {
        if (k is! String || v is! List) return;
        final List<String> list = <String>[
          for (final Object? g in v)
            if (g is String && g.trim().isNotEmpty) g.trim(),
        ];
        if (list.isNotEmpty) out[k] = list;
      });
      Log.i('CATALOGUE_STORE 已恢复用户手动风格 ${out.length} 首');
      return out;
    } catch (e) {
      Log.w('CATALOGUE_STORE 手动风格读取失败（忽略）：$e');
      return <String, List<String>>{};
    }
  }

  /// 写入用户手动的风格归属。
  Future<void> saveOverrides(Map<String, List<String>> overrides) async {
    final Directory? dir = await _dir();
    if (dir == null) return;
    await _atomicWrite(_overridesFile(dir), jsonEncode(overrides));
    Log.i('CATALOGUE_STORE 用户手动风格已落盘 ${overrides.length} 首');
  }

  // ── 序列化细节 ────────────────────────────────────────────

  /// 风格归属的 JSON 形态：`{guid: [{"g":风格,"s":来源,"c":置信度}]}`。
  ///
  /// 存来源与置信度（而不是只存风格名）是需求 §三.6 的明确要求：
  /// 「保留规则版本和来源」，页面才能标出「推断」而不是冒充原始标签。
  static Map<String, List<Map<String, dynamic>>> encodeAssignments(
    Map<String, List<GenreAssignment>> assignments,
  ) =>
      <String, List<Map<String, dynamic>>>{
        for (final MapEntry<String, List<GenreAssignment>> e
            in assignments.entries)
          e.key: <Map<String, dynamic>>[
            for (final GenreAssignment a in e.value)
              <String, dynamic>{
                'g': a.genre,
                's': a.source.name,
                'c': a.confidence,
              },
          ],
      };

  static Map<String, List<GenreAssignment>> decodeAssignments(Object? raw) {
    final Map<String, List<GenreAssignment>> out =
        <String, List<GenreAssignment>>{};
    if (raw is! Map) return out;
    raw.forEach((Object? key, Object? value) {
      if (key is! String || value is! List) return;
      final List<GenreAssignment> list = <GenreAssignment>[];
      for (final Object? item in value) {
        if (item is! Map) continue;
        final String genre = (item['g'] as String?) ?? '';
        if (genre.trim().isEmpty) continue;
        list.add(GenreAssignment(
          genre: genre,
          source: _sourceOf(item['s']),
          confidence: (item['c'] as num?)?.toDouble() ?? 0,
        ));
      }
      if (list.isNotEmpty) out[key] = list;
    });
    return out;
  }

  static GenreSource _sourceOf(Object? raw) {
    for (final GenreSource s in GenreSource.values) {
      if (s.name == raw) return s;
    }
    // 未知来源按**最弱**处理：宁可被更强的结果覆盖，也不要冒充高置信度。
    return GenreSource.artistRule;
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
