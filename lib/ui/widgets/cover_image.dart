import 'package:flutter/material.dart';

import '../../core/log.dart';
import '../../repositories/music_repository.dart';

/// 封面图片。
///
/// ## 关键约束（V2 要求 §9）
/// **封面加载失败绝不能影响音乐播放，也绝不能抛 exception。**
/// 因此这里做了三层保护：
/// 1. `errorBuilder` —— 网络失败/404 时显示占位符，而不是让错误冒泡；
/// 2. `loadingBuilder` —— 加载中显示占位符，避免布局跳动；
/// 3. 全部子组件都包在 `ErrorWidget.builder` 之外 —— 任何意外都退化为占位符。
///
/// 认证：封面是受保护资源（需 `Cookie: music-token`），
/// 复用 [MusicRepository.authHeaders]，token 不会进 URL。
class CoverImage extends StatelessWidget {
  final MusicRepository music;
  final String? coverId;

  /// 方形边长（DIP）。
  final double size;

  /// 圆角。
  final double radius;

  /// 占位符图标大小。
  final double iconScale;

  const CoverImage({
    super.key,
    required this.music,
    required this.coverId,
    required this.size,
    this.radius = 6,
    this.iconScale = 0.4,
  });

  /// 同一张封面失败只记一次日志。
  ///
  /// 曲库可能有几千行，滚动时同一张封面会反复触发 `errorBuilder`；
  /// 不去重会把日志刷爆（V2 要求 §20「不要疯狂输出」）。
  static final Set<String> _loggedFailures = <String>{};

  @override
  Widget build(BuildContext context) {
    final id = coverId;
    final placeholder = _placeholder(context);
    if (id == null || id.isEmpty) {
      return SizedBox(width: size, height: size, child: placeholder);
    }

    final url = music.buildCoverUrl(id);
    final headers = music.authHeaders;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        // ⚠️ 一张图片失败绝不能拖垮整页：错误一律替换为占位符。
        child: Image.network(
          url,
          headers: headers.isEmpty ? null : headers,
          fit: BoxFit.cover,
          gaplessPlayback: true, // 换歌时保留旧图，避免闪白
          errorBuilder: (context, err, stack) {
            if (_loggedFailures.add(id)) {
              Log.w('COVER_LOAD_ERROR coverId=$id '
                  '（同一封面只记一次，失败已降级为占位符）');
            }
            return placeholder;
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return placeholder;
          },
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFF1E1E26),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: size * iconScale,
        color: Colors.white24,
      ),
    );
  }
}
