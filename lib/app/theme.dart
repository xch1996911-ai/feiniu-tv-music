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
  static const Color bg = Color(0xFF0E0E16);

  /// 左侧导航栏底色。
  static const Color sidebar = Color(0xFF131320);

  /// 卡片 / 面板底色。
  static const Color panel = Color(0xFF191926);

  /// 卡片高亮态（选中导航项 / 列表当前播放行）。
  static const Color panelHi = Color(0xFF23233A);

  /// 分割线 / 描边。
  static const Color line = Color(0xFF2A2A3A);

  // ── 播放页（图三）─────────────────────────────────────────
  /// 播放页渐变起色（左上，偏亮的墨绿）。
  static const Color stageFrom = Color(0xFF1C4632);

  /// 播放页渐变止色（右下，近黑墨绿）。
  static const Color stageTo = Color(0xFF07160F);

  /// 播放页里的次级面板（进度条槽、圆底按钮）。
  static const Color stagePanel = Color(0x33000000);

  // ── 文字 ──────────────────────────────────────────────────
  static const Color text = Color(0xFFFFFFFF);
  static const Color textDim = Color(0xFFB6B6C6);
  static const Color textFaint = Color(0xFF7A7A8C);

  // ── 品牌与强调 ────────────────────────────────────────────
  /// 飞牛品牌红（Logo / 强调点）。
  static const Color brand = Color(0xFFFF3B30);

  /// 交互强调蓝（进度条已播段、当前播放行）。
  static const Color accent = Color(0xFF4F8CFF);

  /// 成功 / 在线。
  static const Color ok = Color(0xFF54D68A);

  /// 警告。
  static const Color warn = Color(0xFFFFC24B);

  // ── 焦点（电视端最关键的一组色）──────────────────────────
  /// 焦点描边。刻意用高亮度冷色，在深蓝底和深绿底上都能一眼分辨。
  static const Color focusRing = Color(0xFF9CC4FF);

  /// 焦点填充（描边内部的底色）。
  static const Color focusFill = Color(0xFF24334F);

  /// 按下态（OK/Enter 已按下但还没抬起）。比焦点态更亮，用于**区分**两种状态。
  static const Color pressedFill = Color(0xFF3F6BD8);
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
