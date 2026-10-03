import 'package:feiniu_tv_music/core/exceptions.dart';
import 'package:feiniu_tv_music/core/result.dart';
import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';

/// 假歌词源：让歌词逻辑能在无网络环境下被测试。
///
/// 与 [FakeMusicRepository] 同样的思路 —— 真实实现未登录时会抛
/// `StateError`，因此覆写 [getLyrics]。
class FakeLyricSource extends MusicRepository {
  FakeLyricSource({this.fail = false, LyricDoc? doc})
      : _doc = doc ?? LyricDoc.empty,
        super(AuthRepository());

  /// 让 getLyrics 返回错误（测「歌词失败不影响播放」）。
  final bool fail;

  final LyricDoc _doc;

  /// 记录被请求过的曲目 guid（断言只加载当前歌曲）。
  final List<String> requestedGuids = <String>[];

  @override
  Future<Result<LyricDoc>> getLyrics(String trackGuid) async {
    requestedGuids.add(trackGuid);
    if (fail) {
      return const Result<LyricDoc>.err(
        AppError('歌词接口失败', kind: ErrorKind.network),
      );
    }
    return Result<LyricDoc>.ok(_doc);
  }

  /// 一份带时间轴的样例歌词（供需要走真实解析路径的测试使用）。
  ///
  /// ⚠️ `LyricDoc.parseLrc` 返回的是 `List<LyricLine>`，不是 `LyricDoc`，
  /// 这里要显式包一层。
  static FakeLyricSource sample() => FakeLyricSource(
        doc: LyricDoc(
          lines: LyricDoc.parseLrc(
            '[00:00.00]第一行歌词\n'
            '[00:05.00]第二行歌词\n'
            '[00:10.00]第三行歌词\n',
          ),
        ),
      );
}
