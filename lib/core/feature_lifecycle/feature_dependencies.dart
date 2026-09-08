import 'feature_lifecycle.dart';

/// Reads relationships exclusively from persisted data, without operation flags.
abstract final class FeatureDependencies {
  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toSet().toList(growable: false)
      : const [];

  static Map _lifecycle(Map<String, dynamic> data) {
    final value = data[FeatureLifecycleContract.dataKey];
    return value is Map ? value : const {};
  }

  static bool _hasReferences(Map<String, dynamic> data) =>
      data.containsKey('references') || data.containsKey('sourceIds');

  /// References retain their own purpose even when explicit dependencies exist.
  static List<String> references(Map<String, dynamic> data) {
    final result = <String>{
      ..._strings(data['references']),
      ..._strings(data['sourceIds']),
    };
    final sketch = data['sketch'];
    final metadata = sketch is Map ? sketch['metadata'] : null;
    final support = metadata is Map ? metadata['supportEntityId'] : null;
    if (support is String) result.add(support);
    final sketchEntity = data['sketchEntity'];
    final entityMetadata = sketchEntity is Map
        ? sketchEntity['metadata']
        : null;
    if (entityMetadata is Map) {
      result.addAll(_strings(entityMetadata['sourceEntityIds']));
    }
    if (result.isEmpty && !_hasReferences(data)) {
      result.addAll(_strings(_lifecycle(data)['references']));
    }
    return result.toList(growable: false);
  }

  static List<String> resolve(Map<String, dynamic> data) {
    if (data.containsKey('dependencies')) return _strings(data['dependencies']);
    final result = references(data).toSet();
    if (result.isEmpty && !_hasReferences(data)) {
      result.addAll(_strings(_lifecycle(data)['dependencyIds']));
    }
    final source = data['sourceEntityId'];
    if (source is String) result.add(source);
    return result.toList(growable: false);
  }
}
