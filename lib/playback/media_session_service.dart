import 'package:audio_service/audio_service.dart';

import 'playback_engine.dart';

/// MediaSession / 后台播放初始化。
///
/// 通过 audio_service 注册 [PlaybackHandler]，使：
/// - 应用在后台持续播放（前台服务 + 通知/媒体会话）。
/// - 电视遥控器 / 蓝牙耳机的媒体键（Play/Pause/Next/Prev）路由到引擎。
class MediaSessionService {
  MediaSessionService._();

  static Future<PlaybackHandler> init() async {
    final handler = await AudioService.init(
      builder: () => PlaybackHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.feiniu.tv.music.audio',
        androidNotificationChannelName: '飞牛音乐',
        androidNotificationIcon: 'mipmap/ic_launcher',
        // 电视场景无通知栏，但 MediaSession 仍需常驻以保证后台播放与媒体键。
      ),
    );
    return handler as PlaybackHandler;
  }
}
