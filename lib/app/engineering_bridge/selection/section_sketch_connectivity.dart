import '../../../core/geometric_kernel/geometry/vectors.dart';

/// Orders Section segments using the same quantized endpoint rule used when
/// the Section records its effective connectivity. Points are never moved.
class SectionSketchConnectivity {
  const SectionSketchConnectivity._();

  static List<List<Vector3>> orderChains(
    Iterable<Object?> rawSegments, {
    required double tolerance,
  }) {
    if (!tolerance.isFinite || tolerance <= 0) {
      throw ArgumentError.value(tolerance, 'tolerance');
    }
    final segments = rawSegments
        .map(
          (raw) => (raw as List)
              .map((point) => Vector3.fromJson(point as List))
              .toList(),
        )
        .where((segment) => segment.length == 2)
        .toList();
    if (segments.isEmpty) return const [];
    String key(Vector3 point) =>
        '${(point.x / tolerance).round()}:${(point.y / tolerance).round()}:${(point.z / tolerance).round()}';
    final byEndpoint = <String, List<int>>{};
    for (var index = 0; index < segments.length; index++) {
      for (final point in segments[index]) {
        byEndpoint.putIfAbsent(key(point), () => <int>[]).add(index);
      }
    }
    final used = List<bool>.filled(segments.length, false);
    final output = <List<Vector3>>[];
    for (var seed = 0; seed < segments.length; seed++) {
      if (used[seed]) continue;
      used[seed] = true;
      final first = segments[seed];
      final chain = <Vector3>[first[0], first[1]];
      var extended = true;
      while (extended) {
        extended = false;
        final candidates = byEndpoint[key(chain.last)] ?? const <int>[];
        for (final candidateIndex in candidates) {
          if (used[candidateIndex]) continue;
          final candidate = segments[candidateIndex];
          if (key(candidate[0]) == key(chain.last)) {
            chain.add(candidate[1]);
          } else if (key(candidate[1]) == key(chain.last)) {
            chain.add(candidate[0]);
          } else {
            continue;
          }
          used[candidateIndex] = true;
          extended = true;
          break;
        }
      }
      output.add(chain);
    }
    return output;
  }
}
