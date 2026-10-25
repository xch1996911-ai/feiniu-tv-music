import 'package:flutter/material.dart';

/// 全局调色板（对齐「飞牛音乐」参考图）。
///
/// ## 为什么单独抽一个类
/// 参考图里主界面是**深蓝紫底 + 暖色卡片**，播放页是**深绿底 + 亮色焦点环**。
/// 两套底色都必须在电视上保证「3 米外能看清焦点在哪」，因此色值集中在
/// 这里定义，页面不再各自写 `Color(0x...)`，避免改一处漏一处。
///
/// ⚠️ 这里只是**新增**色板，[buildTvTheme] 的既有取值（scaffoldBackgroundColor、
/// textTheme 字号）被 `test/boot_theme_test.dart` 锁住，不允许改动。
class TvColors {
  const TvColors._();

  // ── 主界面（图二）─────────────────────────────────────────
  /// 应用主背景（比参考图稍深，避免电视上泛灰）。
  static const Color bg = Color(0xFF0D0D15);

  /// 左侧导航栏底色。
  static const Color sidebar = Color(0xFF121220);

  /// 卡片 / 面板底色。
  static const Color panel = Color(0xFF1A1A28);

  /// 卡片高亮态（选中导航项 / 列表当前播放行）。
  static const Color panelHi = Color(0xFF242438);

  /// 分割线 / 描边。
  static const Color line = Color(0xFF2B2B3C);

  // ── 播放页（图三）─────────────────────────────────────────
  /// 播放页渐变起色（左上，偏亮的墨绿）。
  static const Color stageFrom = Color(0xFF1B4130);

  /// 播放页渐变止色（右下，近黑墨绿）。
  static const Color stageTo = Color(0xFF07130E);

  /// 播放页里的次级面板（进度条槽、圆底按钮）。
  static const Color stagePanel = Color(0x33000000);

  // ── 文字 ──────────────────────────────────────────────────
  static const Color text = Color(0xFFFFFFFF);
  static const Color textDim = Color(0xFFB9B9C8);
  static const Color textFaint = Color(0xFF7C7C90);

  // ── 品牌与强调 ────────────────────────────────────────────
  /// 飞牛品牌红（Logo / 强调点）。
  static const Color brand = Color(0xFFFF3B30);

  /// 交互强调蓝（进度条已播段、当前播放行）。
  static const Color accent = Color(0xFF5B8CFF);

  /// 成功 / 在线。
  static const Color ok = Color(0xFF54D68A);

  /// 警告。
  static const Color warn = Color(0xFFFFC24B);

  // ── 焦点（电视端最关键的一组色）──────────────────────────
  /// 焦点描边。**冷白蓝**，比纯电光蓝更克制 —— 85 英寸近距离观看时
  /// 高饱和蓝边会在深底上「发紫」，反而看不清边界。
  static const Color focusRing = Color(0xFFA9C9FF);

  /// 焦点填充（描边内部的底色）。
  static const Color focusFill = Color(0xFF22304B);

  /// 按下态（OK/Enter 已按下但还没抬起）。比焦点态更亮，用于**区分**两种状态。
  static const Color pressedFill = Color(0xFF3D66CC);

  // ── 毛玻璃视觉体系（V4 新增）──────────────────────────────
  /// 玻璃面：半透明深色。
  ///
  /// 透明度是**电视上实测调出来**的：再透一点会被背景内容干扰、
  /// 文字对比度下降；再实一点就退化成普通不透明面板，「玻璃感」消失。
  static const Color glass = Color(0xB3141420);

  /// 更亮一档的玻璃 —— 用于需要「浮在更上层」的弹窗 / 队列面板。
  static const Color glassHi = Color(0xCC1C1C2B);

  /// 玻璃面上的细边线。刻意比 [line] 淡：整页都用硬边框会显得很碎。
  static const Color glassLine = Color(0x26FFFFFF);

  /// 弹窗背后的遮罩（比玻璃更暗，且**不做模糊**，让焦点留在弹窗上）。
  static const Color scrim = Color(0xB3000000);

  /// 玻璃面外阴影。
  static const Color glassShadow = Color(0x59000000);
}

/// 圆角 token（UI 2.0 形式化）。
///
/// 之前各处手写 `BorderRadius.circular(14/16/18/20/22)`，同一层级的控件
/// 圆角不一致，整页看起来「碎」。收敛成四档后，页面只按**语义**取值。
class TvRadii {
  const TvRadii._();

  /// 列表行 / 小控件 / 封面。
  static const double tile = 12;

  /// 卡片（Bento 卡、统计卡）。
  static const double card = 16;

  /// 毛玻璃面板（导航栏、迷你播放器、弹层）。
  static const double glass = 20;

  /// 胶囊（搜索栏、文字按钮）。
  static const double pill = 22;

  /// 圆形键（播放控制键）。实际取 `size / 2`，此值仅用于语义化胶囊按钮。
  static const double button = 999;
}

/// 间距 token（4 的倍数，页面内边距统一 22–26）。
class TvSpacing {
  const TvSpacing._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 26;
  static const double xxl = 34;

  /// 页面内容区内边距（左/右 26、底 26）。
  static const double pageH = 26;
  static const double pageBottom = 26;
}

/// 动效 token。
///
/// 电视端的原则：**快而不跳**。焦点反馈超过 200ms 会觉得「跟不上按键」，
/// 低于 100ms 又看不出过渡（尤其在 60Hz 面板上只有 6 帧）。
class TvMotion {
  const TvMotion._();

  /// 焦点态变化（描边/底色/浮起）。
  static const Duration focus = Duration(milliseconds: 160);

  /// 按下态淡出。
  static const Duration pressed = Duration(milliseconds: 200);

  /// 按下态的视觉保持（物理按键 KeyUp 可能丢，靠定时器复位）。
  static const Duration pressedHold = Duration(milliseconds: 240);

  /// 歌词滚动。
  static const Duration lyricScroll = Duration(milliseconds: 280);

  /// 播放页背景交叉淡化。
  static const Duration backgroundCrossFade = Duration(milliseconds: 600);

  /// 卡片浮起。
  static const Duration cardLift = Duration(milliseconds: 150);
}

/// 焦点「浮起」倍率。
///
/// ⚠️ 只用于**卡片**，列表行一律 1.0：
/// - 列表行密密麻麻，放大后相邻行互相压边，反而看不出焦点在哪；
/// - 卡片面积大、四周有留白，放大 3% 才能在 3 米外看出「这一张被选中了」。
class TvLift {
  const TvLift._();

  static const double none = 1.0;

  /// 首页 Bento 卡。
  static const double card = 1.03;

  /// 专辑 / 封面大卡（上限 1.04）。
  static const double album = 1.04;
}

/// 焦点光环（Halo）参数。
///
/// 85 英寸近距离观看时，`alpha 0.30 / blur 14` 会在深色背景上糊出一团蓝雾，
/// 焦点边界反而变模糊。默认降到 `0.18 / 8`，只给主播放键保留强光环。
class TvHalo {
  const TvHalo._();

  static const double alpha = 0.18;
  static const double blur = 8.0;

  /// 主操作键（播放/暂停）用的强光环。
  static const double strongAlpha = 0.30;
  static const double strongBlur = 14.0;
}

/// 全局主题（TV 场景：深背景 + 大字号 + 高对比）。
///
/// 抽到独立文件是因为**启动引导页与主 App 必须共用同一套主题**：
/// 引导页在 `main()` 里最先渲染，主 App 在初始化完成后接管，
/// 两者若各写一份，会在切换瞬间出现样式跳变。
///
/// ⚠️ 取值被 `test/boot_theme_test.dart` 锁定，改动前先看那个测试。
ThemeData buildTvTheme() => ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xFF0B0B0F),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 18),
        titleMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
        titleLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
      ),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF4F8CFF),
        surface: Color(0xFF15151C),
      ),
    );
