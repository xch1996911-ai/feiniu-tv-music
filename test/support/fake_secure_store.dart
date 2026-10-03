import 'package:feiniu_tv_music/services/secure_store.dart';

/// 内存版 [SecureStore]：只覆盖 V2 新增的**播放偏好**方法。
///
/// ## 为什么需要它
/// `PlaybackRepository` 的状态恢复走 `SecureStore`，而真实实现依赖
/// `flutter_secure_storage`（Android Keystore）。在纯 Dart 单测里既没有平台通道，
/// 也不该真写设备存储。
///
/// ## 为什么用 `extends` 而不是 `implements`
/// `SecureStore` 还有一堆登录凭据 / deviceId 方法。这里用 `extends` 只覆盖
/// 播放偏好那 6 个，**继承**其余的（测试根本不会调用它们），
/// 免去 `implements` 必须实现全部成员的样板代码。
class FakeSecureStore extends SecureStore {
  final Map<String, String> prefs = <String, String>{};

  @override
  Future<String?> readPlayModeKey() async => prefs['playMode'];

  @override
  Future<void> writePlayModeKey(String value) async {
    prefs['playMode'] = value;
  }

  @override
  Future<String?> readLastTrackGuid() async => prefs['lastGuid'];

  @override
  Future<void> writeLastTrackGuid(String guid) async {
    prefs['lastGuid'] = guid;
  }

  @override
  Future<int?> readLastPositionMs() async {
    final v = prefs['lastPosMs'];
    return v == null ? null : int.tryParse(v);
  }

  @override
  Future<void> writeLastPositionMs(int ms) async {
    prefs['lastPosMs'] = ms.toString();
  }

  @override
  Future<void> clearLastPlayback() async {
    prefs.remove('lastGuid');
    prefs.remove('lastPosMs');
  }

  // ── 本机收听历史（首页「最近播放」用）────────────────────

  /// 与真实实现保持**同样的线格式**（`\n` 分隔），否则「持久化往返」
  /// 测试就测不到真实的序列化/反序列化分支了。
  @override
  Future<List<String>> readRecentGuids() async {
    final raw = prefs['recentGuids'];
    if (raw == null || raw.isEmpty) return const <String>[];
    return raw
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<void> writeRecentGuids(List<String> guids) async {
    prefs['recentGuids'] = guids.take(SecureStore.maxRecentTracks).join('\n');
  }
}
