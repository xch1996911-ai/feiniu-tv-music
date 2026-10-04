import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/ui/pages/login_page.dart';
import 'package:feiniu_tv_music/ui/widgets/tv_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_store.dart';

/// 小米电视 S Pro 2025 登录输入故障的修复回归。
///
/// ## 实机故障
/// 登录页能选中输入框，但**按 OK 系统软键盘不弹出**，
/// NAS 地址 / 用户名 / 密码一个都输不进去 ⇒ 完全无法登录。
///
/// ## 修复的两条路（都要被测到）
/// 1. **显式唤起系统键盘**：字段获得焦点后经原生通道再唤一次
///    （测试环境没有插件 ⇒ 返回 false，正是「电视 ROM 没有可用 IME」的场景）；
/// 2. **应用内遥控器键盘兜底**：等待 [LoginPage.imeProbeDelay] 后系统键盘仍未出现
///    （判据 `viewInsets.bottom == 0`，测试环境恒真）→ 自动打开屏幕键盘。
///
/// 全部用**真实键盘事件**驱动（arrowUp/Down/Left/Right/enter），不直接调回调。
///
/// ## 键盘布局（测试里的导航依据）
/// ```
/// r0  1 2 3 4 5 6 7 8 9 0
/// r1  q w e r t y u i o p
/// r2  a s d f g h j k l
/// r3  Aa z x c v b n m ⌫
/// r4  . : - _ / @ * $
/// r5  空格 清空 显示 完成
/// ```
/// 焦点链规则：左右同行、上下相邻行同列（列越界收敛到该行最后一个键）；
/// 行首/行尾与首/末行**原地不动**，因此「从第 0 列一路向下」是稳定路径。
void main() {
  FocusNode? nodeForLabel(WidgetTester tester, String label) {
    for (final Focus f in tester.widgetList<Focus>(find.byType(Focus))) {
      if (f.focusNode?.debugLabel == label) return f.focusNode;
    }
    return null;
  }

  String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, [int times = 1]) async {
    for (int i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
  }

  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  // ── 应用内键盘本身 ────────────────────────────────────────

  group('TvKeyboard（遥控器屏幕键盘）', () {
    late TextEditingController controller;
    var closed = 0;
    var obscureChanges = <bool>[];

    Future<void> pumpKeyboard(
      WidgetTester tester, {
      bool obscure = false,
    }) async {
      controller = TextEditingController();
      closed = 0;
      obscureChanges = <bool>[];
      addTearDown(controller.dispose);

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTvTheme(),
          home: Scaffold(
            body: TvKeyboard(
              controller: controller,
              fieldLabel: obscure ? '密码' : 'NAS 地址（含端口）',
              obscure: obscure,
              onObscureChanged: (bool v) => obscureChanges.add(v),
              onClose: () => closed++,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('打开后焦点落在第一颗按键上（不依赖 autofocus）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpKeyboard(tester);
      expect(focusedLabel(), 'tvkbd.1',
          reason: '键盘必须自带初始焦点，否则遥控器第一下方向键没有起点');

      await tearDownTree(tester);
    });

    testWidgets('方向键 + OK 能输入数字 / 字母 / 符号（IP 与端口需要的点号、冒号）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpKeyboard(tester);

      // 数字
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '1');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'tvkbd.2');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '12');

      // 字母（回到第 0 列再向下）
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'tvkbd.q');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '12q');

      // 符号：q → a → Aa → '.'
      await press(tester, LogicalKeyboardKey.arrowDown, 3);
      expect(focusedLabel(), 'tvkbd.dot');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '12q.');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'tvkbd.colon');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '12q.:');

      await tearDownTree(tester);
    });

    testWidgets('退格 / 清空 / 完成（完成必须回调 onClose）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpKeyboard(tester);

      // 输一个字符再退格
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '1');
      await press(tester, LogicalKeyboardKey.arrowDown, 3); // → Aa
      await press(tester, LogicalKeyboardKey.arrowRight, 8); // → ⌫
      expect(focusedLabel(), 'tvkbd.bsp');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '', reason: '退格必须真的删掉一个字符');

      // 再输一个字符 → 走回第 0 列 → 末行 → 清空
      await press(tester, LogicalKeyboardKey.arrowUp); // r2 末列（l）
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, 'l');
      await press(tester, LogicalKeyboardKey.arrowLeft, 8); // → r2c0（a）
      await press(tester, LogicalKeyboardKey.arrowDown); // Aa
      await press(tester, LogicalKeyboardKey.arrowDown); // .
      await press(tester, LogicalKeyboardKey.arrowDown); // 空格
      expect(focusedLabel(), 'tvkbd.space');
      await press(tester, LogicalKeyboardKey.arrowRight); // 清空
      expect(focusedLabel(), 'tvkbd.clear');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, '');

      // 完成
      await press(tester, LogicalKeyboardKey.arrowRight, 2); // 显示 → 完成
      expect(focusedLabel(), 'tvkbd.done');
      await press(tester, LogicalKeyboardKey.enter);
      expect(closed, 1, reason: '完成必须关闭键盘（把焦点交还调用方）');

      await tearDownTree(tester);
    });

    testWidgets('大小写切换与密码显隐（顶栏显示当前编辑字段）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpKeyboard(tester, obscure: true);

      expect(find.text('正在编辑：密码'), findsOneWidget);
      expect(find.text('小写'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowDown, 3); // → Aa
      expect(focusedLabel(), 'tvkbd.shift');
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text('大写'), findsOneWidget, reason: '要有明确的状态反馈');

      // 大写态下输 z → 'Z'
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'tvkbd.z');
      await press(tester, LogicalKeyboardKey.enter);
      expect(controller.text, 'Z');

      // 显示 / 隐藏
      await press(tester, LogicalKeyboardKey.arrowDown); // 符号行同列
      await press(tester, LogicalKeyboardKey.arrowDown); // 清空
      await press(tester, LogicalKeyboardKey.arrowRight); // 显示
      expect(focusedLabel(), 'tvkbd.obscure');
      await press(tester, LogicalKeyboardKey.enter);
      expect(obscureChanges, <bool>[false],
          reason: '密码字段初始为掩码，切换后应变为明文');

      await tearDownTree(tester);
    });

    testWidgets('键盘内部方向键不越界（首行 ↑ / 末行 ↓ 原地不动）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpKeyboard(tester);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'tvkbd.1', reason: '首行按 ↑ 不能跑出键盘');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'tvkbd.1', reason: '行首按 ← 不能跑出键盘');

      await press(tester, LogicalKeyboardKey.arrowDown, 5);
      expect(focusedLabel(), 'tvkbd.space', reason: '应停在末行');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'tvkbd.space', reason: '末行按 ↓ 不能跑出键盘');

      await tearDownTree(tester);
    });
  });

  // ── 登录页整合 ────────────────────────────────────────────

  group('LoginPage：系统键盘不可用时兜底到屏幕键盘', () {
    Future<void> pumpLogin(
      WidgetTester tester, {
      Size physical = const Size(1920, 1080),
      double dpr = 1.0,
    }) async {
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthRepository>.value(
              value: AuthRepository(store: FakeSecureStore()),
            ),
          ],
          child: MaterialApp(
            theme: buildTvTheme(),
            home: LoginPage(onLoggedIn: () {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    /// 推进到「系统键盘没出来 → 自动打开遥控器键盘」这一步。
    Future<void> waitForFallback(WidgetTester tester) async {
      await tester.pump(
          LoginPage.imeProbeDelay + const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('等待系统键盘超时 → 自动打开遥控器键盘（并给出说明文案）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);

      expect(find.byType(TvKeyboard), findsNothing,
          reason: '刚进页面不该立刻弹键盘（先给系统输入法一次机会）');

      await waitForFallback(tester);

      expect(find.byType(TvKeyboard), findsOneWidget,
          reason: '系统键盘没出现时必须自动给用户一条能输入的通道');
      expect(find.textContaining('已自动打开遥控器键盘'), findsOneWidget);
      expect(focusedLabel(), 'tvkbd.1', reason: '键盘必须自己拿到焦点');

      await tearDownTree(tester);
    });

    testWidgets('键盘打开时返回键先关键盘（PopScope.canPop == false）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await waitForFallback(tester);

      expect(find.byType(TvKeyboard), findsOneWidget);
      final PopScope<Object?> pop =
          tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>));
      expect(pop.canPop, isFalse, reason: '键盘打开时返回键必须先关掉键盘');

      await tearDownTree(tester);
    });

    testWidgets('「完成」关闭键盘 → 焦点回到正在编辑的字段，且不会自动弹回',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await waitForFallback(tester);
      expect(find.byType(TvKeyboard), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowDown, 5); // 空格
      await press(tester, LogicalKeyboardKey.arrowRight, 3); // 完成
      expect(focusedLabel(), 'tvkbd.done');
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.byType(TvKeyboard), findsNothing);
      expect(focusedLabel(), 'login.host',
          reason: '关闭键盘后焦点必须回到正在编辑的字段，而不是掉到 FocusScope');

      final PopScope<Object?> pop =
          tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>));
      expect(pop.canPop, isTrue, reason: '键盘已关，返回键回到正常的页面返回逻辑');

      // 远超探测时长：不允许自己弹回来（否则用户会觉得「关不掉」）
      await tester.pump(LoginPage.imeProbeDelay + const Duration(seconds: 2));
      await tester.pump();
      expect(find.byType(TvKeyboard), findsNothing,
          reason: '用户手动关掉的键盘不允许自动重开');

      await tearDownTree(tester);
    });

    testWidgets('密码字段：键盘写入密码框控制器，且保持掩码',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);

      // 在探测计时器到点之前，把焦点挪到密码框
      final FocusNode? pass = nodeForLabel(tester, 'login.pass');
      expect(pass, isNotNull, reason: '密码框必须在焦点树上');
      pass!.requestFocus();
      await tester.pump();

      await waitForFallback(tester);

      expect(find.byType(TvKeyboard), findsOneWidget);
      expect(find.text('正在编辑：密码'), findsOneWidget,
          reason: '键盘必须明确显示当前编辑的是哪一栏');

      await press(tester, LogicalKeyboardKey.enter); // 输入 '1'

      final TextField passField =
          tester.widgetList<TextField>(find.byType(TextField)).last;
      expect(passField.controller?.text, '1',
          reason: '必须真的写进密码框的控制器');
      expect(passField.obscureText, isTrue, reason: '密码默认掩码');

      await tearDownTree(tester);
    });

    testWidgets('小逻辑视口（960×540）下键盘不溢出、末行按键仍在',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, physical: const Size(960, 540));
      await waitForFallback(tester);

      expect(find.byType(TvKeyboard), findsOneWidget);
      // 键高由可用高度反推；一旦写死就会在这里 RenderFlex 溢出（测试即失败）。
      expect(tester.takeException(), isNull);
      expect(find.text('完成'), findsOneWidget, reason: '末行不能被裁掉');

      await tearDownTree(tester);
    });

    testWidgets('4K 面板（3840×2160 / dpr 2.0 ⇒ 1920×1080 逻辑）键盘正常',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, physical: const Size(3840, 2160), dpr: 2.0);
      await waitForFallback(tester);

      expect(find.byType(TvKeyboard), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('完成'), findsOneWidget);

      await tearDownTree(tester);
    });
  });
}
