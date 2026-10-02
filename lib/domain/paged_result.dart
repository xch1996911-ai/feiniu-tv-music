/// 服务端分页结果。飞牛音乐列表接口统一返回 `{ list: [...], total, sort }`，
/// 这里只保留 Phase 1 真正使用的字段。
class PagedResult<T> {
  final List<T> items;
  final int total;
  final int page;
  final int size;

  const PagedResult({
    required this.items,
    required this.total,
    required this.page,
    required this.size,
  });

  /// 是否还有下一页（用于列表分页加载，避免一次拉全 10 万曲）。
  bool get hasMore => page * size < total;

  PagedResult<T> copyWith({List<T>? items, int? total, int? page, int? size}) =>
      PagedResult(
        items: items ?? this.items,
        total: total ?? this.total,
        page: page ?? this.page,
        size: size ?? this.size,
      );
}
