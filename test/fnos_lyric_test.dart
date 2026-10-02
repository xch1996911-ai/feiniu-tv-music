import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fnos_samples.dart';

void main() {
  group('LyricDoc.fromJson（契约 §7 结构）', () {
    test('读取 list / preferred，并选中 preferred 指定的歌词源', () {
      final data = lyricListResponse()['data']! as Map<String, dynamic>;
      final doc = LyricDoc.fromJson(data);

      expect(doc.sourceCount, 2);
      expect(doc.preferredIndex, 1);
      expect(doc.isNotEmpty, isTrue);
    });

    test('LRC 文本被解析成逐行歌词（时间轴升序）', () {
      final data = lyricListResponse()['data']! as Map<String, dynamic>;
      final doc = LyricDoc.fromJson(data);

      expect(doc.lines.length, 4);
      expect(doc.lines[0].text, isEmpty);
      expect(doc.lines[0].time, Duration.zero);
      expect(doc.lines[1].text, '第一行');
      expect(doc.lines[1].time, const Duration(milliseconds: 12340));
      expect(doc.lines[2].text, '第二行');
      expect(doc.lines[2].time, const Duration(milliseconds: 65500));
      expect(doc.lines[3].text, '第三行');
      expect(doc.lines[3].time, const Duration(milliseconds: 150000));
    });

    test('空 list → empty（不抛异常）', () {
      expect(LyricDoc.fromJson(<String, dynamic>{'list': <dynamic>[]}).isEmpty, isTrue);
      expect(LyricDoc.fromJson(<String, dynamic>{}).isEmpty, isTrue);
      expect(LyricDoc.fromJson(<String, dynamic>{'list': 'bad'}).isEmpty, isTrue);
    });

    test('preferred 缺失时退回首条', () {
      final doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <dynamic>[
          <String, dynamic>{'text': '[00:01.00]only'},
        ],
      });
      expect(doc.preferredIndex, 0);
      expect(doc.lines.single.text, 'only');
    });

    test('preferred 越界时退回下标 0', () {
      final doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <dynamic>[
          <String, dynamic>{'text': '[00:01.00]a'},
          <String, dynamic>{'text': '[00:02.00]b'},
        ],
        'preferred': 99,
      });
      expect(doc.preferredIndex, 0);
      expect(doc.lines.single.text, 'a');
    });

    test('preferred 是对象/字符串时也能定位', () {
      final doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <dynamic>[
          <String, dynamic>{'guid': 'x', 'text': '[00:01.00]x'},
          <String, dynamic>{'guid': 'y', 'text': '[00:02.00]y'},
        ],
        'preferred': <String, dynamic>{'guid': 'y'},
      });
      expect(doc.preferredIndex, 1);
      expect(doc.lines.single.text, 'y');
    });
  });

  group('非 LRC 单条歌词（time / duration / offset 单位为秒）', () {
    test('秒 → Duration', () {
      final doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <dynamic>[
          <String, dynamic>{
            'text': '一整段没有时间标签的歌词',
            'time': 12.5,
            'duration': 3,
            'offset': 0.25,
          },
        ],
      });
      expect(doc.lines.single.text, '一整段没有时间标签的歌词');
      expect(doc.lines.single.time, const Duration(milliseconds: 12500));
      expect(doc.lines.single.duration, const Duration(seconds: 3));
      expect(doc.lines.single.offset, const Duration(milliseconds: 250));
    });
  });

  group('parseLrc', () {
    test('小数位 1/2/3 位都按毫秒正确换算', () {
      expect(LyricDoc.parseLrc('[00:01.5]a').single.time,
          const Duration(milliseconds: 1500));
      expect(LyricDoc.parseLrc('[00:01.50]a').single.time,
          const Duration(milliseconds: 1500));
      expect(LyricDoc.parseLrc('[00:01.123]a').single.time,
          const Duration(milliseconds: 1123));
    });

    test('冒号做小数点也兼容（[mm:ss:ff]）', () {
      expect(LyricDoc.parseLrc('[00:01:25]a').single.time,
          const Duration(milliseconds: 1250));
    });

    test('一行多标签展开为多行（共享行尾文本）并排序', () {
      final lines = LyricDoc.parseLrc('[00:20.00][00:10.00]副歌');
      expect(lines.length, 2);
      expect(lines[0].time, const Duration(seconds: 10));
      expect(lines[1].time, const Duration(seconds: 20));
      expect(lines.every((l) => l.text == '副歌'), isTrue);
    });

    test('文档级 [offset:] 作用于所有行', () {
      final lines = LyricDoc.parseLrc('[offset:500]\n[00:10.00]a');
      expect(lines.single.time, const Duration(milliseconds: 10500));
    });

    test('纯元数据标签被跳过，无时间轴的裸文本保留（无时间）', () {
      final lines = LyricDoc.parseLrc(
        '[ar:某某]\n[ti:某歌]\n[by:someone]\n没有时间轴的说明文字',
      );
      expect(lines.length, 1);
      expect(lines.single.text, '没有时间轴的说明文字');
      expect(lines.single.time, isNull);
    });

    test('空文本返回空列表', () {
      expect(LyricDoc.parseLrc('').isEmpty, isTrue);
      expect(LyricDoc.parseLrc('\n\n  \n').isEmpty, isTrue);
    });
  });
}
