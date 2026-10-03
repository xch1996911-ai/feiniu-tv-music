/// JSON 取值工具：对飞牛返回的类型抖动（`int` / `num` / `String` / `null`）统一兜底。
///
/// Phase 1 之前每个领域模型文件各有一份私有 `_asInt`，容易漂移；这里集中一处。
/// 原则：**绝不对缺失字段抛类型异常** —— 真实 NAS 上前端会把未知/未赋值字段
/// 直接省略（实测 `year: null`、`genres: []`），模型必须容忍。
library;

/// 取 int，缺失或不可解析返回 0。
int jsonInt(dynamic v) => jsonIntOrNull(v) ?? 0;

/// 取 int，缺失或不可解析返回 null。
int? jsonIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 取 double，缺失或不可解析返回 null。
double? jsonDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// 取非空 String，缺失返回 [fallback]。
String jsonString(dynamic v, {String fallback = ''}) =>
    jsonStringOrNull(v) ?? fallback;

/// 取 String，缺失或空串返回 null。
String? jsonStringOrNull(dynamic v) {
  if (v == null) return null;
  final s = v is String ? v : '$v';
  return s.isEmpty ? null : s;
}

/// 取 bool；`1`/`"1"`/`"true"` 视为 true（前端偶有 0/1 表示法）。
bool jsonBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    return s == 'true' || s == '1';
  }
  return false;
}

/// 取字符串数组；非 List 返回空列表，元素为 null 时丢弃。
List<String> jsonStringList(dynamic v) {
  if (v is! List) return const <String>[];
  return v.map(jsonStringOrNull).whereType<String>().toList();
}

/// **Unix 秒** → [DateTime]（本地时区）。
///
/// 真实契约 §4：track / album / artist / user 的 `createdAt` / `updatedAt`
/// **单位是 Unix 秒**（不是毫秒）。传毫秒会让时间直接跑到公元五万年，
/// 因此这里对「疑似毫秒」做一次兼容收敛：大于 `1e11` 的值按毫秒处理。
DateTime? jsonUnixSeconds(dynamic v) {
  final n = jsonIntOrNull(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n > 100000000000 ? n : n * 1000);
}

/// [DateTime] → **Unix 秒**（[jsonUnixSeconds] 的逆运算，口径必须一致）。
///
/// 用于把领域模型写回 JSON：本地曲库索引需要把服务端返回的曲目元数据
/// 落盘，重启后直接反序列化，避免每次启动都全库重拉
/// （见 `lib/services/catalogue_store.dart`）。
int? unixSecondsOf(DateTime? d) =>
    d == null ? null : d.millisecondsSinceEpoch ~/ 1000;
