import 'dart:async';
import 'dart:io';

import 'package:feiniu_tv_music/playback/play_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// `PlaybackLauncher` —— 切歌阻塞事故的**修复本体**回归测试。
///
/// ## 事故回顾（本次审查确认的直接根因）
/// 引擎旧实现是：
/// ```dart
/// await _player.setAudioSource(...);
/// await _player.play();      // ← just_audio 的 play() 直到「播完/暂停/停止」才完成
/// ```
/// 而仓储的加载链是串行的 ⇒ **A 正在播放时点 B，B 的换源要排队等 A 播完**。
/// 但仓储里「当前曲目」早已是 B ⇒ 用户看到「界面/歌词是 B，耳朵里还是 A」。
///
/// 修法：`play()` 的 Future **不等待**，但**也不吞异常**（独立错误通道上报）。
/// 本文件同时用「源码守卫」钉住 `playback_engine.dart` 里不能再出现
/// `await _player.play()` 这种写法。
void main() {
  group('PlaybackLauncher', () {
    test('play() 的 Future 永不完成时，launch 仍然立即返回（绝不被整首歌占住）', () async {
      final launcher = PlaybackLauncher();
      final Completer<void> never = Completer<void>();
      bool playCalled = false;
      Object? error;

      launcher.launch(
        () {
          playCalled = true;
          return never.future; // 真实场景：这首歌要放 4 分钟
        },
        onError: (Object e, StackTrace st) => error = e,
      );

      expect(playCalled, isTrue, reason: 'launch 必须真的把 play() 调起来');
      // 只要这两行能执行到，就说明 launch 没有被 never.future 挂住。
      await Future<void>.delayed(Duration.zero);
      expect(launcher.sessionId, 1);
      expect(error, isNull);
      // 注意：不 complete 这个 Completer —— 它代表「歌曲还在播」。
    });

    test('第二次 launch 复用同一条链：新会话不会等旧会话结束', () async {
      final launcher = PlaybackLauncher();
      final Completer<void> a = Completer<void>();
      final Completer<void> b = Completer<void>();
      final List<String> started = <String>[];

      launcher.launch(() {
        started.add('a');
        return a.future;
      }, onError: (Object e, StackTrace st) => fail('A 不该报错'));
      launcher.launch(() {
        started.add('b');
        return b.future;
      }, onError: (Object e, StackTrace st) => fail('B 不该报错'));

      expect(started, <String>['a', 'b'],
          reason: 'B 必须立刻开始，不需要等 A 播完');
      await Future<void>.delayed(Duration.zero);
      expect(launcher.sessionId, 2);
    });

    test('播放期间 Future 失败 → 通过 onError 显式上报（绝不静默丢弃）', () async {
      final launcher = PlaybackLauncher();
      final Completer<void> session = Completer<void>();
      Object? got;
      StackTrace? gotStack;

      launcher.launch(
        () => session.future,
        onError: (Object e, StackTrace st) {
          got = e;
          gotStack = st;
        },
      );
      session.completeError(StateError('网络中断'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(got, isA<StateError>(), reason: '被 await 掉的异常就是用户听不到的故障');
      expect(gotStack, isNotNull);
    });

    test('过期会话的异常被丢弃（用户已经点了别的歌）', () async {
      final launcher = PlaybackLauncher();
      final Completer<void> old = Completer<void>();
      Object? got;

      launcher.launch(() => old.future, onError: (Object e, StackTrace st) => got = e);
      launcher.invalidate(); // 例如 stop() / stopSession()
      old.completeError(StateError('迟到的旧错误'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(got, isNull,
          reason: '过期会话报错会让用户以为「新歌也坏了」，必须丢弃');
    });

    test('isCurrent() 为 false 时丢弃（音源已换成别的曲子）', () async {
      final launcher = PlaybackLauncher();
      final Completer<void> session = Completer<void>();
      bool current = true;
      Object? got;

      launcher.launch(
        () => session.future,
        onError: (Object e, StackTrace st) => got = e,
        isCurrent: () => current,
      );
      current = false; // 用户已经切到别的歌
      session.completeError(StateError('旧歌失败'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(got, isNull);
    });

    test('play() 同步抛出 → 立刻上报（不吞、也不误报成功）', () {
      final launcher = PlaybackLauncher();
      Object? got;
      launcher.launch(
        () => throw StateError('boom'),
        onError: (Object e, StackTrace st) => got = e,
      );
      expect(got, isA<StateError>());
    });
  });

  group('源码守卫（防止事故被改回去）', () {
    test('播放引擎里不得出现「等待播放生命周期」的写法', () {
      // ⚠️ 先把注释行剔掉再检查：本文件的文档注释里**故意**引用了
      //    「不要写 await _player.play()」这句话，不剔注释会把说明文字
      //    当成违规代码（第一轮 CI 就是这么误报的）。
      final String code = File('lib/playback/playback_engine.dart')
          .readAsLinesSync()
          .where((String l) {
        final String t = l.trimLeft();
        return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
      }).join('\n');

      expect(RegExp(r'await\s+_player\.play\(\)').hasMatch(code), isFalse,
          reason: 'just_audio 的 play() 直到播完/暂停/停止才完成，'
              'await 它会让串行加载链被整首歌占住（「界面是 B、声音是 A」的根因）。'
              '必须经 PlaybackLauncher 触发。');
      expect(code.contains('PlaybackLauncher'), isTrue,
          reason: 'play() 必须走「触发 + 独立错误通道」的启动器');
    });
  });
}
