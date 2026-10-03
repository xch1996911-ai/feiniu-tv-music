import 'package:audio_service/audio_service.dart';

import 'playback_engine.dart';
import '../core/branding.dart';

/// MediaSession / 后台播放初始化。
///
/// 通过 audio_service 注册 [PlaybackHandler]，使：
/// - 应用在后台持续播放（前台服务 + 通知/媒体会话）。
/// - 电视遥控器 / 蓝牙耳机的媒体键（Play/Pause/Next/Prev）路由到引擎。
class MediaSessionService {
  MediaSessionService._();

  /// 初始化 MediaSession / 后台播放。
  ///
  /// ⚠️ **必须自带超时**：部分 Android TV ROM 上 `audio_service` 会一直等待
  /// `MediaPlaybackService` 绑定成功，既不抛异常也不完成 —— 表现同样是黑屏。
  /// 超时后由 [BootApp] 捕获并降级为本地播放引擎（App 内仍可播放，
  /// 只是没有后台播放与遥控媒体键），不让一个可选能力拖死整个启动流程。
  static Future<PlaybackHandler> init() {
    return AudioService.init(
      builder: () => PlaybackHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.feiniu.tv.music.audio',
        androidNotificationChannelName: kAppName,
        androidNotificationIcon: 'mipmap/ic_launcher',
        // 电视场景无通知栏，但 MediaSession 仍需常驻以保证后台播放与媒体键。
      ),
    ).timeout(const Duration(seconds: 15));
  }
}
