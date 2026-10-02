import 'package:feiniu_tv_music/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主题回归测试。
///
/// 动机：真实故障中 App 在电视上**纯黑屏**。当时的排查依赖一条约定 ——
/// 「启动引导页与主界面共用同一套主题」。主题抽到 [buildTvTheme] 之后，
/// 需要防止它被改坏（例如被改成浅色背景，会让引导页上的白色诊断文案看不清，
/// 恰恰是最需要看清的时候）。
void main() {
  group('buildTvTheme（启动引导页与主界面共用）', () {
    test('深色背景，保证白色诊断文案可读', () {
      final theme = buildTvTheme();
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0B0B0F));
      expect(theme.colorScheme.brightness, Brightness.dark);
    });

    test('大字号，满足客厅 3 米观看距离', () {
      final theme = buildTvTheme();
      expect(theme.textTheme.titleLarge?.fontSize, 30.0);
      expect(theme.textTheme.titleMedium?.fontSize, 20.0);
      expect(theme.textTheme.bodyMedium?.fontSize, 18.0);
    });

    test('同一份 ThemeData 可同时被引导页与主界面使用', () {
      final app = MaterialApp(
        theme: buildTvTheme(),
        home: const SizedBox.shrink(),
      );
      expect(app.theme?.scaffoldBackgroundColor, const Color(0xFF0B0B0F));
    });
  });
}
