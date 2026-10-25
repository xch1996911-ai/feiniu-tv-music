import 'package:feiniu_tv_music/ui/tv_display.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 显示档位（UI 2.0）。
///
/// ## 为什么必须先钉住判定规则
/// 「4K 电视」不是一个布局条件：同一块 3840×2160 面板可能上报
/// dpr 1.0 / 1.5 / 2.0 / 4.0，对应逻辑视口 3840×2160 / 2560×1440 /
/// 1920×1080 / 960×540。只看物理分辨率就会在 dpr=4 的机器上把界面放大 4 倍。
///
/// 这里的断言全部是**纯函数**（不依赖 Widget 树），真机上再用
/// `Diagnostics.note('显示档位', …)` 记录一次实际值做校准。
void main() {
  group('resolve：逻辑视口优先', () {
    test('960×540（1080p 面板 dpr2 / 4K 面板 dpr4）→ compactTV', () {
      expect(
        TvDisplay.resolve(
          logical: const Size(960, 540),
          physical: const Size(1920, 1080),
        ),
        TvDisplayProfile.compactTV,
      );
      // 4K 面板 + dpr4：逻辑同样是 960×540，绝不能被当成大屏
      expect(
        TvDisplay.resolve(
          logical: const Size(960, 540),
          physical: const Size(3840, 2160),
        ),
        TvDisplayProfile.compactTV,
      );
    });

    test('853×480（720p 面板 dpr1.5，最小现实视口）→ compactTV', () {
      expect(
        TvDisplay.resolve(
          logical: const Size(853, 480),
          physical: const Size(1280, 720),
        ),
        TvDisplayProfile.compactTV,
      );
    });

    test('1280×720 与 1920×1080 → standardTV', () {
      expect(
        TvDisplay.resolve(
          logical: const Size(1280, 720),
          physical: const Size(1920, 1080),
        ),
        TvDisplayProfile.standardTV,
      );
      // 4K 面板 dpr2（85 英寸海信最常见的上报值）
      expect(
        TvDisplay.resolve(
          logical: const Size(1920, 1080),
          physical: const Size(3840, 2160),
        ),
        TvDisplayProfile.large4KTV,
      );
    });

    test('4K 原生 3840×2160（dpr1）→ large4KTV', () {
      expect(
        TvDisplay.resolve(
          logical: const Size(3840, 2160),
          physical: const Size(3840, 2160),
        ),
        TvDisplayProfile.large4KTV,
      );
    });

    test('2560×1440（4K 面板 dpr1.5）→ large4KTV', () {
      expect(
        TvDisplay.resolve(
          logical: const Size(2560, 1440),
          physical: const Size(3840, 2160),
        ),
        TvDisplayProfile.large4KTV,
      );
    });
  });

  group('字号倍率', () {
    test('compact / standard 不放大，large4K 温和放大', () {
      expect(TvDisplay.lyricScale(TvDisplayProfile.compactTV), 1.0);
      expect(TvDisplay.lyricScale(TvDisplayProfile.standardTV), 1.0);
      expect(TvDisplay.lyricScale(TvDisplayProfile.large4KTV), greaterThan(1.0));

      expect(TvDisplay.titleScale(TvDisplayProfile.compactTV), 1.0);
      expect(TvDisplay.titleScale(TvDisplayProfile.standardTV), 1.0);
      expect(TvDisplay.titleScale(TvDisplayProfile.large4KTV), greaterThan(1.0));
    });

    test('放大倍率上限 1.1（避免把布局撑破）', () {
      for (final TvDisplayProfile p in TvDisplayProfile.values) {
        expect(TvDisplay.lyricScale(p), lessThanOrEqualTo(1.1));
        expect(TvDisplay.titleScale(p), lessThanOrEqualTo(1.1));
      }
    });
  });

  test('label 与枚举一一对应（诊断页/日志不要出现两个名字）', () {
    expect(TvDisplay.label(TvDisplayProfile.compactTV), 'compactTV');
    expect(TvDisplay.label(TvDisplayProfile.standardTV), 'standardTV');
    expect(TvDisplay.label(TvDisplayProfile.large4KTV), 'large4KTV');
  });
}
