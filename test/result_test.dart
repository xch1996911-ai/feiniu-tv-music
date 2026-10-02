import 'package:feiniu_tv_music/core/exceptions.dart';
import 'package:feiniu_tv_music/core/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ok 分支', () {
    final r = Result.ok(42);
    expect(r.isOk, isTrue);
    expect(r.isErr, isFalse);
    expect(r.value, 42);
  });

  test('Err 分支', () {
    final r = Result.err<String>(AppError('boom', kind: ErrorKind.network));
    expect(r.isErr, isTrue);
    expect(r.error.kind, ErrorKind.network);
    expect(r.error.message, 'boom');
  });

  test('map 仅作用于成功值', () {
    final r = Result.ok(2).map((v) => v * 3);
    expect(r.value, 6);
    final e = Result.err<int>(AppError('x')).map((v) => v * 3);
    expect(e.isErr, isTrue);
  });

  test('getOrElse 失败回退', () {
    final e = Result.err<int>(AppError('x'));
    expect(e.getOrElse((_) => -1), -1);
  });
}
