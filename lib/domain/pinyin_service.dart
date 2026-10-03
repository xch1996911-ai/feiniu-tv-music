import 'package:pinyin/pinyin.dart';

import 'pinyin_lexicon.dart';
import 'text_norm.dart';

/// 一段文本的「逐字对齐读法」。
///
/// [text] 的第 `i` 个 rune，对应的拼音是 `syllables[i]`、首字母是 `initials[i]`。
/// 非汉字（拉丁字母、假名、韩文…）的 [syllables] / [initials] **就是它自己**，
/// 于是「Jay周杰伦」这种中英混排不需要任何特例分支即可正确匹配。
///
/// ## 为什么要"逐字对齐"而不是只存一整串拼音
///
/// 需求（拼音模糊搜索 §3）要求支持**混合查询**，例如
/// 「周 jie 伦」「周jl」「Jay 周杰伦」。
/// 只存 `zhoujielun` / `zjl` 两个整串的话：
/// - `周jl` 既不是 `周杰伦` 的子串，也不是 `zhoujielun` 的子串 → **搜不到**；
/// - `jie伦` 同理。
///
/// 有了逐字对齐，「每一个字可以用它的汉字、整音节、音节前缀或首字母来消费查询」
/// 就变成一个纯粹的字符串推进问题，混合输入自然成立。
class AlignedText {
  const AlignedText({
    required this.text,
    required this.syllables,
    required this.initials,
    required this.full,
    required this.initialsFlat,
  });

  /// 归一化后的原文（用于"汉字原位匹配"）。
  final String text;

  /// 与 [text] 的 rune 一一对应的音节（无音调、小写；`ü` 已写成 `v`）。
  final List<String> syllables;

  /// 与 [text] 的 rune 一一对应的首字母。
  final List<String> initials;

  /// `syllables.join()` —— 整串拼音（`周杰伦` → `zhoujielun`）。
  final String full;

  /// `initials.join()` —— 整串首字母（`周杰伦` → `zjl`）。
  final String initialsFlat;

  static const AlignedText empty = AlignedText(
    text: '',
    syllables: <String>[],
    initials: <String>[],
    full: '',
    initialsFlat: '',
  );

  /// 用**已缓存**的音节表重建（拼音索引持久缓存用，见 `SearchIndexStore`）。
  ///
  /// [initials] 由 [syllables] 推导 —— 它本来就是"每个音节的首字符"，
  /// 单独存一份只会让缓存文件白白大一倍。
  ///
  /// 若音节个数与 [text] 的字数不一致（缓存损坏 / 规则漂移），
  /// 返回 null，调用方回落到完整的 [PinyinService.align]。
  static AlignedText? fromSyllables(String text, List<String> syllables) {
    if (text.isEmpty) return null;
    if (syllables.length != text.runes.length) return null;
    final List<String> ini = List<String>.filled(syllables.length, '');
    final StringBuffer full = StringBuffer();
    final StringBuffer initialsFlat = StringBuffer();
    for (int i = 0; i < syllables.length; i++) {
      final String s = syllables[i];
      final String head = s.isEmpty ? '' : s[0];
      ini[i] = head;
      full.write(s);
      initialsFlat.write(head);
    }
    return AlignedText(
      text: text,
      syllables: syllables,
      initials: ini,
      full: full.toString(),
      initialsFlat: initialsFlat.toString(),
    );
  }

  bool get isEmpty => text.isEmpty;

  int get length => syllables.length;
}

/// 汉字 → 拼音（含项目自维护的多音字词典）。
///
/// ## 为什么不用 `PinyinHelper.getPinyin` 直接转换
///
/// 那个入口在**每个字符位置**都会对"剩下的整段"做一次简繁转换
/// （`convertToSimplifiedChinese`，内部又是按位置的最长词组匹配），
/// 于是单条标题的开销是 `O(L² × 最长词组长度)`。
/// 实测语料 2796 首、标题平均 15 字，这样一轮全库索引要多花
/// **好几秒**，而且全花在"这段文本里根本没有繁体字"的重复判断上。
///
/// 这里的做法是：
/// 1. **先用一次 O(n) 扫描**判断整段是否含繁体字，只有含繁体才整段转简体；
/// 2. 再自己对**词组表**做最长匹配（`PinyinHelper.phraseMap` 是公开的），
///    逐字回落用 `convertToPinyinArray`。
///
/// 结果与库内入口一致，但没有那层平方级开销。
class PinyinService {
  PinyinService._();

  /// 读法规则的版本号。
  ///
  /// ⚠️ 它参与**拼音索引缓存的失效判定**（`SearchIndexStore`）：
  /// 只要这里的对齐算法变了（换库、改简繁策略、改 `ü` 写法…），
  /// 旧缓存必须整份重算，否则会出现「新算法 + 旧键」的混合索引。
  /// 与 [PinyinLexicon.version] 一起构成"读法键"的版本对。
  static const int version = 1;

  /// 项目词典是否已注册（注册是幂等的，但词组表加载很贵，必须只做一次）。
  static bool _dictReady = false;

  /// 音节串驻留表：把内容相同的音节/首字母复用同一个 `String` 对象。
  ///
  /// 3000 首曲目 × 3 字段 × 每字段十几个音节，会产生几十万个短字符串，
  /// 其中绝大多数是 `de` / `yi` / `wo` 这类高频音节。
  /// 驻留之后内存占用能降一个量级（电视盒子内存不宽裕）。
  static final Map<String, String> _interned = <String, String>{};

  /// 驻留表容量上限：超过之后不再新增（避免异常输入把内存吃满）。
  static const int _internLimit = 6000;

  /// 确保项目词典已注册 `pinyin` 包。失败时静默降级为"只用内置读音"。
  static void ensureReady() {
    if (_dictReady) return;
    _dictReady = true;
    try {
      PinyinHelper.addPhraseMap(PinyinLexicon.entries);
      // 词典里有 8 字词组（"给我一首歌的时间"），必须保证最长匹配能覆盖到。
      //
      // ⚠️ `maxMultiLength` / `minMultiLength` 在 pinyin 3.x 里**已废弃**
      //    （analyzer 会报 deprecated_member_use，本项目 info 也判失败），
      //    新名字是 `maxPhraseLength` / `minPhraseLength`。
      final int need = PinyinLexicon.longestPhraseLength;
      if (PinyinHelper.maxPhraseLength < need) {
        PinyinHelper.maxPhraseLength = need;
      }
    } catch (_) {
      // 词典注册失败不该让搜索整体不可用：内置读音仍然可用。
    }
  }

  /// 文本里是否含**繁体字**（用于决定要不要做简繁转换）。
  static bool containsTraditional(String text) {
    for (final int r in text.runes) {
      if (!TextNorm.isHan(r)) continue;
      if (ChineseHelper.isTraditionalChinese(String.fromCharCode(r))) {
        return true;
      }
    }
    return false;
  }

  /// 整段转简体（仅在 [containsTraditional] 为真时才调用）。
  static String toSimplified(String text) {
    try {
      return ChineseHelper.convertToSimplifiedChinese(text);
    } catch (_) {
      return text;
    }
  }

  /// 与 [align] 相同的「原文侧」处理：**已归一化**的文本 → 对齐用的原文。
  ///
  /// 单独抽出来是为了让**缓存重建**（`SearchIndexStore`）不必重新跑一遍
  /// 昂贵的拼音转换，就能得到与 [align] 完全一致的 `AlignedText.text`
  /// —— 简繁转换必须两边同步，否则缓存回来的下标会对不上原文。
  static String alignedSource(String normalized) {
    if (normalized.isEmpty) return '';
    return containsTraditional(normalized)
        ? toSimplified(normalized)
        : normalized;
  }

  /// 把**已经归一化**的文本对齐成逐字读法。
  static AlignedText align(String normalized) {
    if (normalized.isEmpty) return AlignedText.empty;
    ensureReady();

    // 简繁：含繁体才整段转换（一次），转换后再对齐。
    // ⚠️ 只影响索引键，`Track.title` 等展示字段一个字节都不动。
    final String src = alignedSource(normalized);

    final List<int> runes = src.runes.toList();
    final int n = runes.length;
    final List<String> syllables = List<String>.filled(n, '');
    final List<String> initials = List<String>.filled(n, '');
    final Map<String, String> phraseMap = PinyinHelper.phraseMap;
    final int minPhrase = PinyinHelper.minMultiLength;
    final int maxPhrase = PinyinHelper.maxMultiLength;

    int i = 0;
    while (i < n) {
      final int r = runes[i];
      if (!TextNorm.isHan(r)) {
        // 非汉字：整串原样保留（归一化已经保证是小写字母/数字）。
        final String ch = String.fromCharCode(r);
        syllables[i] = _intern(ch);
        initials[i] = syllables[i];
        i++;
        continue;
      }

      // 1) 词组最长匹配（`重庆` / `单依纯` / `音乐` …）。
      bool matched = false;
      final int upper = (i + maxPhrase) <= n ? i + maxPhrase : n;
      for (int end = upper; end - i >= minPhrase; end--) {
        final String word = String.fromCharCodes(runes.sublist(i, end));
        final String? value = phraseMap[word];
        if (value == null || value.isEmpty) continue;
        final List<String> parts = value.split(',');
        // ⚠️ 读音个数必须等于字数，否则整条不可信 —— 宁可退回逐字，
        //    也不能让一个写错的词典条目把整首歌的索引错位。
        if (parts.length != end - i) continue;
        for (int k = 0; k < parts.length; k++) {
          final String p = _plain(parts[k]);
          syllables[i + k] = _intern(p);
          initials[i + k] = p.isEmpty ? '' : _intern(p[0]);
        }
        i += parts.length;
        matched = true;
        break;
      }
      if (matched) continue;

      // 2) 逐字回落。
      final String ch = String.fromCharCode(r);
      String p = _charPinyin(ch);
      if (p.isEmpty) {
        // 字库以简体为主：繁体单字先转简体再取读音。
        final String simp = ChineseHelper.convertCharToSimplifiedChinese(ch);
        if (simp != ch && simp.runes.length == 1) p = _charPinyin(simp);
      }
      syllables[i] = _intern(p);
      initials[i] = p.isEmpty ? '' : _intern(p[0]);
      i++;
    }

    final StringBuffer full = StringBuffer();
    final StringBuffer ini = StringBuffer();
    for (int k = 0; k < n; k++) {
      full.write(syllables[k]);
      ini.write(initials[k]);
    }
    return AlignedText(
      text: src,
      syllables: syllables,
      initials: initials,
      full: full.toString(),
      initialsFlat: ini.toString(),
    );
  }

  /// 单字读音（无音调、小写）。取不到返回空串。
  static String _charPinyin(String ch) {
    try {
      final List<String> arr =
          PinyinHelper.convertToPinyinArray(ch, PinyinFormat.WITHOUT_TONE);
      return arr.isEmpty ? '' : arr.first;
    } catch (_) {
      return '';
    }
  }

  /// 去掉音调、统一 `ü` → `v`。
  ///
  /// 直接复用 `pinyin` 包的实现（它会做 ü→v 与去重），
  /// 但对纯 ASCII 走快路径 —— 绝大多数音节本来就是纯 ASCII，
  /// 快路径能省掉 32 次 `replaceAll`。
  static String _plain(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return '';
    if (_isPlainAscii(s)) return s;
    try {
      final List<String> arr = PinyinHelper.convertWithoutTone(s);
      return arr.isEmpty ? s : arr.first;
    } catch (_) {
      return s;
    }
  }

  static bool _isPlainAscii(String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      final bool ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);
      if (!ok) return false;
    }
    return true;
  }

  /// 短字符串驻留（内容相同 → 同一个对象）。
  static String _intern(String s) {
    if (s.isEmpty || s.length > 4) return s;
    final String? hit = _interned[s];
    if (hit != null) return hit;
    if (_interned.length < _internLimit) _interned[s] = s;
    return s;
  }

  /// **仅供测试**：清空驻留表。
  static void debugResetInternCache() => _interned.clear();
}
