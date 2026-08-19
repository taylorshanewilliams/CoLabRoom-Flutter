import 'package:shared_preferences/shared_preferences.dart';

/// Persists drag-to-reorder tile order for the Toolbox locally on-device —
/// this is a personal display preference over static bundled content, not
/// data that needs to sync across devices or through Supabase.
abstract final class ToolboxOrderStore {
  static Future<List<String>> load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key) ?? const <String>[];
  }

  static Future<void> save(String key, List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, order);
  }
}

/// Reorders [items] to match [order] (a list of ids), keeping any items not
/// mentioned in [order] appended at the end in their original order — so a
/// newly-added category/sheet just shows up at the end instead of vanishing.
List<T> applyToolboxOrder<T>(List<T> items, List<String> order, String Function(T) idOf) {
  final byId = {for (final item in items) idOf(item): item};
  final result = <T>[];
  for (final id in order) {
    final item = byId.remove(id);
    if (item != null) result.add(item);
  }
  result.addAll(byId.values);
  return result;
}
