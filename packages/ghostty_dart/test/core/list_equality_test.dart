import 'package:ghostty_dart/src/core/internal.dart';
import 'package:test/test.dart';

void main() {
  test('listEquals compares length and elements in order', () {
    final list = [1, 2, 3];
    expect(listEquals(list, list), isTrue);
    expect(listEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(listEquals(<int>[], <int>[]), isTrue);
    expect(listEquals([1, 2], [1, 2, 3]), isFalse);
    expect(listEquals([1, 2, 3], [1, 3, 2]), isFalse);
    expect(listEquals(['a', 'b'], ['a', 'b']), isTrue);
    expect(listEquals([1.0], [1]), isTrue, reason: 'element ==');
  });
}
