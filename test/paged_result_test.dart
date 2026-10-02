import 'package:feiniu_tv_music/domain/paged_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hasMore 判断', () {
    expect(
      PagedResult(items: const [], total: 100, page: 1, size: 10).hasMore,
      isTrue,
    );
    expect(
      PagedResult(items: const [], total: 10, page: 1, size: 10).hasMore,
      isFalse,
    );
    expect(
      PagedResult(items: const [], total: 5, page: 1, size: 10).hasMore,
      isFalse,
    );
  });
}
