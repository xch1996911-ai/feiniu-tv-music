/// 播放页的两种展示模式（本轮新增）。
///
/// ## 为什么放在 domain 层
/// 它是**纯数据**（一个可持久化的选择），不依赖任何 Flutter 类型。
/// 放在这里，仓储层（`LocalLibraryRepository`）与 UI 层都能引用，
/// 且不会让数据层反向依赖 UI。
///
/// ## 两种模式的差别
/// - [stage]  —— 图四的标准布局：左侧大封面 + 曲目信息，右侧歌词，
///   底部一行播放控制。信息密度高，适合「边听边看歌词」。
/// - [cover]  —— 封面模式：封面**明显放大**成为视觉主体，歌词移到封面下方，
///   适合电视远距离观看（3 米外也能看清封面）。
///
/// 两种模式共用同一份播放状态与同一套焦点节点，切换只改版式，
/// **不会重建播放器、不会丢焦点**。
enum PlayerLayout {
  /// 图四标准布局（默认）。
  stage,

  /// 封面 + 歌词（大封面）。
  cover;

  /// 持久化用的稳定字符串。
  ///
  /// 刻意不用 `index`：枚举顺序一旦调整，历史用户的选择会被错读。
  String get storageKey => switch (this) {
        PlayerLayout.stage => 'stage',
        PlayerLayout.cover => 'cover',
      };

  /// 界面上的短标签。
  String get shortLabel => switch (this) {
        PlayerLayout.stage => '标准',
        PlayerLayout.cover => '大封面',
      };

  /// 解析持久化值；未知/空值一律回落到 [PlayerLayout.stage]。
  static PlayerLayout fromStorage(String? raw) {
    for (final PlayerLayout v in PlayerLayout.values) {
      if (v.storageKey == raw) return v;
    }
    return PlayerLayout.stage;
  }

  /// 下一个模式（切换按钮用），循环。
  PlayerLayout get next =>
      PlayerLayout.values[(index + 1) % PlayerLayout.values.length];
}
