import 'dart:math' as math;

import '../../../core/cad_kernel/io/kernel_io_models.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../../core/surface_recognition/models/surface_recognition_models.dart';
import 'mesh_bvh.dart';
import 'surface_selection_policy.dart';

enum RecognitionSelectionTool { select, add, remove, brushAdd, brushRemove }

extension RecognitionSelectionToolMode on RecognitionSelectionTool {
  bool get isBrush =>
      this == RecognitionSelectionTool.brushAdd ||
      this == RecognitionSelectionTool.brushRemove;
  bool get isAdditive =>
      this == RecognitionSelectionTool.add ||
      this == RecognitionSelectionTool.brushAdd;
}

final class SelectionEdit {
  const SelectionEdit({
    required this.added,
    required this.removed,
    required this.label,
  });

  final Set<int> added;
  final Set<int> removed;
  final String label;
}

/// Transient, non-document selection over triangles of the original mesh.
///
/// The model never changes [geometry]. Adjacency is built lazily because most
/// selections only need automatic recognition and never enter an edit tool.
final class EditableSurfaceSelection {
  EditableSurfaceSelection({
    required this.projectId,
    required this.meshId,
    required this.meshFingerprint,
    required this.entityId,
    required this.geometry,
    required Set<int> initialTriangles,
    required this.area,
  }) : initialTriangles = Set.unmodifiable(initialTriangles),
       currentTriangles = Set.unmodifiable(initialTriangles);

  static const maxTrianglesForAdjacency = 600000;
  static const maxEdgesForAdjacency = 1800000;
  static const maxLocalPatchTriangles = 96;

  final String projectId;
  final String meshId;
  final String meshFingerprint;
  final String entityId;
  final KernelMeshGeometry geometry;
  final Set<int> initialTriangles;
  Set<int> currentTriangles;
  double area;
  int revision = 0;

  Map<(int, int), int>? _edgeFirst;
  Map<(int, int), int>? _edgeSecond;
  MeshBvh? _bvh;
  MeshSurfaceData? _surfaceData;
  List<Vector3>? _surfaceNormals;
  List<Set<int>>? _surfaceAdjacency;

  bool get isEdited => !_sameTriangles(initialTriangles, currentTriangles);
  bool get isEmpty => currentTriangles.isEmpty;
  int get triangleCount => currentTriangles.length;
  MeshBvh get bvh => _bvh ??= MeshBvh(geometry);
  MeshSurfaceData get surfaceData =>
      _surfaceData ??= MeshSurfaceData.fromKernel(geometry);

  List<Vector3> get surfaceNormals => _surfaceNormals ??= [
    for (
      var triangle = 0;
      triangle < geometry.triangles.length ~/ 3;
      triangle++
    )
      triangleNormal(geometry, triangle),
  ];

  List<Set<int>> get surfaceAdjacency {
    final cached = _surfaceAdjacency;
    if (cached != null) return cached;
    _ensureAdjacency();
    final triangleCount = geometry.triangles.length ~/ 3;
    final adjacency = List<Set<int>>.generate(
      triangleCount,
      (_) => <int>{},
      growable: false,
    );
    for (final key in _edgeFirst!.keys) {
      final first = _edgeFirst![key];
      final second = _edgeSecond![key];
      if (first == null || second == null || first == second) continue;
      adjacency[first].add(second);
      adjacency[second].add(first);
    }
    return _surfaceAdjacency = adjacency;
  }

  int connectedComponentCount([Set<int>? subset]) {
    final selected = subset ?? currentTriangles;
    if (selected.isEmpty) return 0;
    final adjacency = surfaceAdjacency;
    final visited = <int>{};
    var components = 0;
    for (final seed in selected) {
      if (!visited.add(seed)) continue;
      components++;
      final pending = <int>[seed];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        for (final neighbor in adjacency[current]) {
          if (selected.contains(neighbor) && visited.add(neighbor)) {
            pending.add(neighbor);
          }
        }
      }
    }
    return components;
  }

  double areaOfTriangle(int triangle) => triangleArea(geometry, triangle);

  Set<int> neighborsOf(int triangle) {
    _ensureAdjacency();
    final first = _edgeFirst!;
    final second = _edgeSecond!;
    final result = <int>{};
    final offset = triangle * 3;
    final triangles = geometry.triangles;
    final ids = [
      triangles[offset],
      triangles[offset + 1],
      triangles[offset + 2],
    ];
    for (var index = 0; index < 3; index++) {
      final key = _edgeKey(ids[index], ids[(index + 1) % 3]);
      final a = first[key];
      final b = second[key];
      if (a != null && a != triangle) result.add(a);
      if (b != null && b != triangle) result.add(b);
    }
    return result;
  }

  Set<int> localAdd(int seed, {int? limit}) {
    final patchLimit = limit ?? _localPatchLimit();
    _validateTriangle(seed);
    if (currentTriangles.contains(seed)) {
      throw StateError('O triângulo clicado já pertence à seleção.');
    }
    if (!neighborsOf(seed).any(currentTriangles.contains)) {
      throw StateError('O triângulo clicado não é adjacente à seleção atual.');
    }
    final added = <int>{};
    final visited = <int>{seed};
    final pending = <int>[seed];
    while (pending.isNotEmpty && added.length < patchLimit) {
      final triangle = pending.removeLast();
      if (currentTriangles.contains(triangle)) continue;
      added.add(triangle);
      for (final neighbor in neighborsOf(triangle)) {
        if (!currentTriangles.contains(neighbor) && visited.add(neighbor)) {
          pending.add(neighbor);
        }
      }
    }
    return added;
  }

  Set<int> localRemove(int seed, {int? limit}) {
    _validateTriangle(seed);
    if (!currentTriangles.contains(seed)) {
      throw StateError('O triângulo clicado não pertence à seleção.');
    }
    if (currentTriangles.length <= 1) {
      throw StateError('A seleção precisa manter pelo menos um triângulo.');
    }
    final removed = <int>{};
    final visited = <int>{seed};
    final pending = <int>[seed];
    final allowed = math.min(
      limit ?? _localPatchLimit(),
      currentTriangles.length - 1,
    );
    while (pending.isNotEmpty && removed.length < allowed) {
      final triangle = pending.removeLast();
      if (!currentTriangles.contains(triangle)) continue;
      removed.add(triangle);
      for (final neighbor in neighborsOf(triangle)) {
        if (currentTriangles.contains(neighbor) && visited.add(neighbor)) {
          pending.add(neighbor);
        }
      }
    }
    return removed;
  }

  Set<int> expandRing() {
    if (currentTriangles.isEmpty) return const {};
    final added = <int>{};
    for (final triangle in currentTriangles) {
      for (final neighbor in neighborsOf(triangle)) {
        if (!currentTriangles.contains(neighbor)) added.add(neighbor);
      }
    }
    return added;
  }

  Set<int> contractRing() {
    if (currentTriangles.isEmpty) return const {};
    final boundary = <int>{};
    for (final triangle in currentTriangles) {
      if (neighborsOf(
        triangle,
      ).any((neighbor) => !currentTriangles.contains(neighbor))) {
        boundary.add(triangle);
      }
    }
    if (boundary.isEmpty) return const {};
    if (boundary.length == currentTriangles.length) {
      boundary.remove(boundary.reduce(math.min));
    }
    return boundary;
  }

  void replaceCurrent(Set<int> triangles, {required double area}) {
    currentTriangles = Set.unmodifiable(triangles);
    this.area = area;
    revision++;
  }

  void _ensureAdjacency() {
    if (_edgeFirst != null && _edgeSecond != null) return;
    final triangleCount = geometry.triangles.length ~/ 3;
    if (triangleCount > maxTrianglesForAdjacency) {
      throw StateError(
        'A malha tem $triangleCount triângulos; edição limitada a '
        '$maxTrianglesForAdjacency.',
      );
    }
    if (triangleCount * 3 > maxEdgesForAdjacency) {
      throw StateError('A malha excede o limite de arestas para edição.');
    }
    final first = <(int, int), int>{};
    final second = <(int, int), int>{};
    final triangles = geometry.triangles;
    for (var triangle = 0; triangle < triangleCount; triangle++) {
      final offset = triangle * 3;
      final ids = [
        triangles[offset],
        triangles[offset + 1],
        triangles[offset + 2],
      ];
      for (var index = 0; index < 3; index++) {
        final key = _edgeKey(ids[index], ids[(index + 1) % 3]);
        final owner = first[key];
        if (owner == null) {
          first[key] = triangle;
        } else if (owner != triangle) {
          second.putIfAbsent(key, () => triangle);
        }
      }
    }
    if (second.isEmpty) {
      throw StateError(
        'Adjacência por aresta indisponível nesta malha; '
        'use uma seleção automática.',
      );
    }
    _edgeFirst = first;
    _edgeSecond = second;
  }

  void _validateTriangle(int triangle) {
    if (triangle < 0 || triangle >= geometry.triangles.length ~/ 3) {
      throw StateError('Triângulo fora da malha original: $triangle.');
    }
  }

  int _localPatchLimit() {
    final triangleCount = geometry.triangles.length ~/ 3;
    return math.min(maxLocalPatchTriangles, math.max(1, triangleCount ~/ 100));
  }

  (int, int) _edgeKey(int a, int b) => a < b ? (a, b) : (b, a);

  bool _sameTriangles(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);
}
