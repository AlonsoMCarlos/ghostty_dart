/// Element-wise list equality for the package's immutable value types.
///
/// Internal and pure Dart (no `dart:ffi`), so value-type files that must
/// stay backend-neutral can import it directly. No barrel exports it.
library;

/// Whether [a] and [b] have the same length and equal elements (`==`) in
/// the same order.
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
