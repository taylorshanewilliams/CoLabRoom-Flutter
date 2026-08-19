class NameConflict implements Exception {
  const NameConflict(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract final class NamePolicy {
  static String clean(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String normalized(String value) => clean(value).toLowerCase();

  static bool same(String left, String right) {
    return normalized(left) == normalized(right);
  }

  static void requireUsable(String value, {String label = 'Name'}) {
    final cleaned = clean(value);
    if (cleaned.isEmpty) {
      throw NameConflict('$label cannot be empty.');
    }
    if (cleaned.length > 80) {
      throw NameConflict('$label must be 80 characters or fewer.');
    }
  }
}
