import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:flutter_test/flutter_test.dart';

/// **增强型 LRC（逐字 / 卡拉 OK 时间标签）** 的解析回归。
///
/// ## 实机故障（用户截图）
/// 歌词区把 `<00:09.71>` `<00:10.01>` 这些**行内逐字时间标签**原样显示出来，
/// 句子被拆碎。旧解析器只认方括号 `[mm:ss.xx]`，把尖括号标签当成了歌词正文。
///
/// 修复要求（按代码审查意见逐条落实）：
/// 1. 同时识别 `[mm:ss.xx]` 与 `<mm:ss.xx>`，**输出给 UI 前必须剥离标签**；
/// 2. 有方括号行时间时优先用它；只有尖括号时取**该行第一个**尖括号时间，
///    使逐行高亮与滚动仍然工作；
/// 3. 中文相邻片段之间的空格要清理（`示 例 歌 词` → `示例歌词`），
///    但英文词间空格必须保留；
/// 4. `informativeCharCount` 先剥离**两类**标签，纯标签内容算 0（判无效）；
/// 5. 元数据、同行多标签、纯文本等既有行为不回归。
void main() {
  group('① 标准 LRC 不回归', () {
    test('`[00:09.71]示例歌词` → 正文干净、时间正确', () {
      final List<LyricLine> lines = LyricDoc.parseLrc('[00:09.71]示例歌词');
      expect(lines.length, 1);
      expect(lines[0].text, '示例歌词');
      expect(lines[0].time, const Duration(milliseconds: 9710));
    });

    test('文档级 offset/元数据标签不回归', () {
      final List<LyricLine> lines = LyricDoc.parseLrc(
        '[ar:某歌手]\n[ti:某歌名]\n[offset:+500]\n[00:09.00]示例',
      );
      // 前两行是元数据（跳过），offset 叠加 500ms。
      expect(lines.length, 1);
      expect(lines[0].text, '示例');
      expect(lines[0].time, const Duration(milliseconds: 9500));
    });

    test('同一行多个方括号时间 → 多个时间点共用同一句正文', () {
      final List<LyricLine> lines = LyricDoc.parseLrc('[00:01.00][00:02.00]重复句');
      expect(lines.length, 2);
      expect(lines.map((LyricLine l) => l.text).toSet(), <String>{'重复句'});
      expect(lines[1].time, const Duration(milliseconds: 2000));
    });
  });

  group('② 用户截图形态（行首方括号 + 行内逐字尖括号）', () {
    test('`[00:09.71] 示 <00:09.95> 例 <00:10.01> 歌 <00:10.30> 词`', () {
      final List<LyricLine> lines = LyricDoc.parseLrc(
        '[00:09.71] 示 <00:09.95> 例 <00:10.01> 歌 <00:10.30> 词',
      );
      expect(lines.length, 1, reason: '一行歌词不能按字拆成多行');
      expect(lines[0].text, '示例歌词',
          reason: '标签必须剥离，中文之间的空格必须清理');
      expect(lines[0].time, const Duration(milliseconds: 9710),
          reason: '有方括号时优先用它作为行时间');
    });

    test('`[00:09.71]<00:09.71>示<00:09.95>例` → 不显示任何尖括号标签', () {
      final List<LyricLine> lines =
          LyricDoc.parseLrc('[00:09.71]<00:09.71>示<00:09.95>例');
      expect(lines.length, 1);
      expect(lines[0].text, '示例');
      expect(lines[0].text.contains('<'), isFalse);
      expect(lines[0].time, const Duration(milliseconds: 9710));
    });

    test('英文歌词的词间空格必须保留（不能被清理规则误删）', () {
      final List<LyricLine> lines =
          LyricDoc.parseLrc('[00:09.71]Hello <00:09.95>world');
      expect(lines[0].text, 'Hello world');
    });

    test('中文正文里的英文词：只清掉中文之间的空格', () {
      final List<LyricLine> lines =
          LyricDoc.parseLrc('[00:01.00]我 <00:01.20>love <00:01.40>你');
      expect(lines[0].text, '我 love 你');
    });
  });

  group('③ 只有尖括号标签的增强型 LRC（要能同步，不能退化成纯文本）', () {
    const String enhanced = '<00:09.71>示例歌词\n<00:12.40>第二句示例\n';

    test('逐行取出正文与**首个**尖括号时间', () {
      final List<LyricLine> lines = LyricDoc.parseLrc(enhanced);
      expect(lines.length, 2);
      expect(lines[0].text, '示例歌词');
      expect(lines[0].time, const Duration(milliseconds: 9710));
      expect(lines[1].text, '第二句示例');
      expect(lines[1].time, const Duration(milliseconds: 12400));
    });

    test('LyricDoc.isSyncable == true（旧实现这里是 false → 永远不跟随）', () {
      final LyricDoc doc = LyricDoc(lines: LyricDoc.parseLrc(enhanced));
      expect(doc.isSyncable, isTrue);
      expect(doc.isEmpty, isFalse);
    });

    test('`LyricDoc.parse`（在线候选解析走这条）也不带标签', () {
      final LyricDoc doc = LyricDoc.parse(enhanced);
      expect(doc.lines.every((LyricLine l) => !l.text.contains('<')), isTrue);
      expect(doc.isSyncable, isTrue);
    });

    test('从 NAS JSON 契约进入时同样剥离（`text` 字段承载增强型 LRC）', () {
      final LyricDoc doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <dynamic>[
          <String, dynamic>{'text': enhanced},
        ],
        'preferred': 0,
      });
      expect(doc.lines.length, 2);
      expect(doc.lines[0].text, '示例歌词');
      expect(doc.lines[0].time, const Duration(milliseconds: 9710));
    });
  });

  group('④ informativeCharCount：先剥离两类标签', () {
    test('纯标签内容算 0（旧实现把标签里的数字算成歌词）', () {
      expect(LyricDoc.informativeCharCount('<00:09.71><00:10.01>'), 0);
      expect(LyricDoc.informativeCharCount('[00:09.71][00:10.01]'), 0);
      expect(LyricDoc.informativeCharCount('♪ ♫ ……'), 0);
    });

    test('混合标签与歌词文字时算作有效', () {
      expect(LyricDoc.informativeCharCount('<00:09.71>示例'), 2);
      expect(LyricDoc.informativeCharCount('Hello'), 5);
    });

    test('只有时间标签的文档 → isUsable == false（在线兜底仍会被触发）', () {
      final LyricDoc onlyTags =
          LyricDoc(lines: LyricDoc.parseLrc('<00:09.71><00:10.01>'));
      expect(onlyTags.isUsable, isFalse);
    });

    test('含真实歌词的增强型 LRC → isUsable == true', () {
      final LyricDoc doc = LyricDoc(lines: LyricDoc.parseLrc('<00:09.71>示例歌词'));
      expect(doc.isUsable, isTrue);
    });
  });

  group('⑤ 纯文本不回归', () {
    test('无任何时间标签 → time 为 null，正文原样保留', () {
      final List<LyricLine> lines = LyricDoc.parseLrc('纯文本第一行\n纯文本第二行');
      expect(lines.length, 2);
      expect(lines.every((LyricLine l) => l.time == null), isTrue);
      expect(lines[0].text, '纯文本第一行');
      expect(LyricDoc(lines: lines).isSyncable, isFalse);
    });

    test('同行混排（方括号时间 + 纯文本尾巴）仍然只算一行', () {
      final List<LyricLine> lines = LyricDoc.parseLrc('[00:05.00]第一段 文字');
      expect(lines.length, 1);
      expect(lines[0].text, '第一段 文字');
    });
  });

  group('⑥ 时间格式兼容', () {
    test('一位小数 / 两位小数 / 三位小数 / 冒号小数 都解析正确', () {
      expect(LyricDoc.parseLrc('[00:01.5]a')[0].time,
          const Duration(milliseconds: 1500));
      expect(LyricDoc.parseLrc('[00:01.25]a')[0].time,
          const Duration(milliseconds: 1250));
      expect(LyricDoc.parseLrc('[00:01.234]a')[0].time,
          const Duration(milliseconds: 1234));
      expect(LyricDoc.parseLrc('[00:01:500]a')[0].time,
          const Duration(milliseconds: 1500));
      expect(LyricDoc.parseLrc('<00:01.25>a')[0].time,
          const Duration(milliseconds: 1250));
    });
  });
}
