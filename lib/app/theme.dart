import 'package:flutter/material.dart';

/// 全局主题（TV 场景：深背景 + 大字号 + 高对比）。
///
/// 抽到独立文件是因为**启动引导页与主 App 必须共用同一套主题**：
/// 引导页在 `main()` 里最先渲染，主 App 在初始化完成后接管，
/// 两者若各写一份，会在切换瞬间出现样式跳变。
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
