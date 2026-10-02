import 'exceptions.dart';

/// 统一结果类型：用类型系统强制调用方处理失败，避免到处 try/catch 或抛异常穿透 UI。
///
/// 示例：
/// ```dart
/// final result = await repo.getTracks(1, 10);
/// if (result.isOk) { final tracks = result.value; }
/// else { final err = result.error; }
/// ```
class Result<T> {
  const Result._();

  /// 成功分支的工厂：通过 [_Ok] 实现。
  const factory Result.ok(T value) = _Ok<T>;

  /// 失败分支的工厂：通过 [_Err] 实现。
  const factory Result.err(AppError error) = _Err<T>;

  bool get isOk => this is _Ok<T>;

  bool get isErr => this is _Err<T>;

  /// 取值，失败时抛 [AppError]（仅在你已确认 isOk 时使用）。
  T get value {
    if (this is _Ok<T>) return (this as _Ok<T>).value;
    throw (this as _Err<T>).error;
  }

  AppError get error {
    if (this is _Err<T>) return (this as _Err<T>).error;
    throw StateError('Result is Ok, no error');
  }

  /// 链式映射成功值。
  Result<U> map<U>(U Function(T) f) =>
      isOk ? Result.ok(f(value)) : Result.err(error);

  /// 失败时回退到默认值。
  T getOrElse(T Function(AppError) f) => isOk ? value : f(error);
}

class _Ok<T> extends Result<T> {
  @override
  final T value;
  const _Ok(this.value) : super._();
}

class _Err<T> extends Result<T> {
  @override
  final AppError error;
  const _Err(this.error) : super._();
}
