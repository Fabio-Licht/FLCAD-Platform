import 'dart:math' as math;

import '../../cad_kernel/io/kernel_io_models.dart';
import '../../geometric_kernel/geometry/vectors.dart';
import '../../geometric_kernel/services/fitting_engine.dart';
import '../models/surface_recognition_models.dart';

class RegionGrowingResult {
  const RegionGrowingResult(
    this.regions,
    this.graph, {
    this.diagnostics = const {},
  });
  final List<SurfaceRegion> regions;
  final RegionGraph graph;
  final Map<String, Object?> diagnostics;
}

/// Runtime-only evidence used to distinguish a locally good plane fit from a
/// planar CAD candidate. It is carried in diagnostics and does not alter mesh
/// geometry or the RegionGrowing selection contract.
enum PlanarClassification {
  localReference,
  planarCadCandidate,
  curvedPatch,
  ambiguous,
}

class ProfessionalRegionGrowing {
  const ProfessionalRegionGrowing();

  RegionGrowingResult segment(
    MeshSurfaceData mesh,
    String meshFingerprint, {
    SurfaceRecognitionSettings settings = const SurfaceRecognitionSettings(),
  }) {
    if (mesh.triangles.isEmpty) {
      return const RegionGrowingResult([], RegionGraph({}));
    }
    final normals = <Vector3>[], areas = <double>[];
    for (final triangle in mesh.triangles) {
      final a = mesh.vertices[triangle.$1],
          b = mesh.vertices[triangle.$2],
          c = mesh.vertices[triangle.$3];
      final cross = (b - a).cross(c - a);
      normals.add(cross.normalized);
      areas.add(cross.length * .5);
    }
    final adjacency = _triangleAdjacency(mesh.triangles);
    final curvature = List<double>.generate(normals.length, (i) {
      final neighbors = adjacency[i];
      if (neighbors.isEmpty) return 0;
      return neighbors
              .map((j) => _angle(normals[i], normals[j]))
              .reduce((a, b) => a + b) /
          neighbors.length;
    });
    if (settings.planar && settings.seedTriangle != null) {
      return _segmentPlanar(
        mesh,
        meshFingerprint,
        normals,
        areas,
        adjacency,
        settings,
      );
    }
    final limit = settings.normalAngleDegrees * math.pi / 180;
    final visited = List<bool>.filled(mesh.triangles.length, false);
    final groups = <Set<int>>[];
    for (var seed = 0; seed < visited.length; seed++) {
      if (visited[seed]) continue;
      final group = <int>{seed}, queue = <int>[seed];
      visited[seed] = true;
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final next in adjacency[current]) {
          if (visited[next] ||
              _angle(normals[current], normals[next]) > limit ||
              (curvature[current] - curvature[next]).abs() >
                  settings.curvatureDelta ||
              (curvature[seed] - curvature[next]).abs() >
                  settings.curvatureDelta) {
            continue;
          }
          visited[next] = true;
          group.add(next);
          queue.add(next);
        }
      }
      groups.add(group);
    }
    _mergeSmall(groups, adjacency, settings.minimumTriangles);
    groups.sort((a, b) => a.reduce(math.min).compareTo(b.reduce(math.min)));
    final triangleRegion = <int, int>{};
    for (var i = 0; i < groups.length; i++) {
      for (final triangle in groups[i]) {
        triangleRegion[triangle] = i;
      }
    }
    final graphEdges = <String, Set<String>>{};
    final regions = <SurfaceRegion>[];
    for (var i = 0; i < groups.length; i++) {
      final id = 'region:$meshFingerprint:${i + 1}';
      final triangles = groups[i].toList()..sort();
      final vertices = <int>{};
      var area = 0.0, normal = Vector3.zero, meanCurvature = 0.0;
      for (final index in triangles) {
        final t = mesh.triangles[index];
        vertices.addAll([t.$1, t.$2, t.$3]);
        area += areas[index];
        normal = normal + normals[index] * areas[index];
        meanCurvature += curvature[index];
      }
      final sortedVertices = vertices.toList()..sort();
      regions.add(
        SurfaceRegion(
          id: id,
          color: _color(i),
          triangleIndices: triangles,
          vertexIndices: sortedVertices,
          area: area,
          averageNormal: normal.normalized,
          bounds: _bounds(sortedVertices.map((v) => mesh.vertices[v]).toList()),
          meanCurvature: meanCurvature / triangles.length,
          confidence: math.min(1, .55 + math.log(triangles.length + 1) / 15),
          health: triangles.length >= settings.minimumTriangles
              ? RecognitionHealth.good
              : RecognitionHealth.low,
        ),
      );
      graphEdges[id] = <String>{};
    }
    for (var i = 0; i < adjacency.length; i++) {
      for (final j in adjacency[i]) {
        final a = triangleRegion[i]!, b = triangleRegion[j]!;
        if (a != b) {
          graphEdges[regions[a].id]!.add(regions[b].id);
          graphEdges[regions[b].id]!.add(regions[a].id);
        }
      }
    }
    return RegionGrowingResult(
      regions,
      RegionGraph(graphEdges),
      diagnostics: {
        'mode': 'generic',
        'visitedTriangles': mesh.triangles.length,
        'selectedTriangles': mesh.triangles.length,
      },
    );
  }

  /// Reuses the existing multiscale planar criteria for an explicit accepted
  /// triangle set. It does not grow or replace the accepted selection; the
  /// full mesh is used only as geometric context for adjacency and stability
  /// samples beyond the boundary.
  Map<String, Object?> classifyPlanarRegion(
    MeshSurfaceData mesh, {
    required Set<int> accepted,
    required int seedTriangle,
    required double planarToleranceMm,
    double normalAngleDegrees = 28,
    int seedNeighborhoodTriangles = 24,
    List<Vector3>? normals,
    List<Set<int>>? adjacency,
  }) {
    if (accepted.isEmpty ||
        seedTriangle < 0 ||
        seedTriangle >= mesh.triangles.length) {
      return const {
        'planarClassification': 'ambiguous',
        'planarStabilityReason': 'invalid-or-empty-accepted-region',
      };
    }
    final prepared = normals != null && adjacency != null
        ? (normals: normals, adjacency: adjacency)
        : _preparePlanarEvidence(mesh);
    if (prepared.normals.length != mesh.triangles.length ||
        prepared.adjacency.length != mesh.triangles.length) {
      throw ArgumentError('Planar evidence does not match the original mesh.');
    }
    final stability = _planarStability(
      mesh: mesh,
      seed: seedTriangle,
      accepted: accepted,
      normals: prepared.normals,
      adjacency: prepared.adjacency,
      tolerance: planarToleranceMm,
      normalLimit: normalAngleDegrees * math.pi / 180,
      seedNeighborhood: seedNeighborhoodTriangles,
    );
    return {
      'mode': 'planar-classification',
      'seedTriangle': seedTriangle,
      'selectedTriangles': accepted.length,
      'toleranceMm': planarToleranceMm,
      ...stability,
    };
  }

  ({List<Vector3> normals, List<Set<int>> adjacency}) _preparePlanarEvidence(
    MeshSurfaceData mesh,
  ) {
    final normals = <Vector3>[];
    for (final triangle in mesh.triangles) {
      final a = mesh.vertices[triangle.$1];
      final b = mesh.vertices[triangle.$2];
      final c = mesh.vertices[triangle.$3];
      normals.add((b - a).cross(c - a).normalized);
    }
    return (normals: normals, adjacency: _triangleAdjacency(mesh.triangles));
  }

  RegionGrowingResult _segmentPlanar(
    MeshSurfaceData mesh,
    String meshFingerprint,
    List<Vector3> normals,
    List<double> areas,
    List<Set<int>> adjacency,
    SurfaceRecognitionSettings settings,
  ) {
    final seed = settings.seedTriangle!;
    if (seed < 0 || seed >= mesh.triangles.length) {
      return const RegionGrowingResult(
        [],
        RegionGraph({}),
        diagnostics: {'mode': 'planar', 'reason': 'invalid-seed'},
      );
    }
    final local = <int>[], pending = <int>[seed], localSeen = <int>{seed};
    while (pending.isNotEmpty &&
        local.length < settings.seedNeighborhoodTriangles) {
      final current = pending.removeLast();
      local.add(current);
      final neighbors = adjacency[current].toList()..sort();
      for (final next in neighbors) {
        if (localSeen.length >= settings.seedNeighborhoodTriangles) break;
        if (localSeen.add(next) &&
            _orientedAngle(normals[seed], normals[next]) <=
                settings.normalAngleDegrees * math.pi / 180) {
          pending.add(next);
        }
      }
    }
    final localVertices = <int>{};
    for (final triangle in local) {
      final value = mesh.triangles[triangle];
      localVertices.addAll([value.$1, value.$2, value.$3]);
    }
    if (localVertices.length < 3) {
      return const RegionGrowingResult(
        [],
        RegionGraph({}),
        diagnostics: {
          'mode': 'planar',
          'reason': 'insufficient-seed-neighborhood',
        },
      );
    }
    final plane = const FittingEngine()
        .fitPlane(localVertices.map((id) => _vertex(mesh, id)).toList())
        .geometry;
    final tolerance = settings.planarToleranceMm;
    if (!tolerance.isFinite || tolerance <= 0) {
      return const RegionGrowingResult(
        [],
        RegionGraph({}),
        diagnostics: {'mode': 'planar', 'reason': 'invalid-tolerance'},
      );
    }
    final accepted = <int>{seed}, queue = <int>[seed], visited = <int>{seed};
    var rejectedByDistance = 0, rejectedByNormal = 0;
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final neighbors = adjacency[current].toList()..sort();
      for (final next in neighbors) {
        if (!visited.add(next)) continue;
        if (_orientedAngle(normals[current], normals[next]) >
            settings.normalAngleDegrees * math.pi / 180) {
          rejectedByNormal++;
          continue;
        }
        final value = mesh.triangles[next];
        final points = [
          _vertex(mesh, value.$1),
          _vertex(mesh, value.$2),
          _vertex(mesh, value.$3),
        ];
        if (points.any(
          (point) => plane.signedDistance(point).abs() > tolerance,
        )) {
          rejectedByDistance++;
          continue;
        }
        accepted.add(next);
        queue.add(next);
      }
    }
    if (accepted.length < settings.minimumTriangles) {
      return RegionGrowingResult(
        [],
        const RegionGraph({}),
        diagnostics: {
          'mode': 'planar',
          'reason': 'insufficient-region',
          'visitedTriangles': visited.length,
          'selectedTriangles': accepted.length,
          'rejectedByDistance': rejectedByDistance,
          'rejectedByNormal': rejectedByNormal,
        },
      );
    }
    final triangles = accepted.toList()..sort();
    final vertices = <int>{};
    var area = 0.0;
    var normal = Vector3.zero;
    var meanCurvature = 0.0;
    for (final index in triangles) {
      final value = mesh.triangles[index];
      vertices.addAll([value.$1, value.$2, value.$3]);
      area += areas[index];
      normal = normal + normals[index] * areas[index];
    }
    final points = vertices.map((id) => _vertex(mesh, id)).toList();
    final bounds = _bounds(points);
    final id = 'region:$meshFingerprint:planar:$seed';
    final region = SurfaceRegion(
      id: id,
      color: _color(seed),
      triangleIndices: triangles,
      vertexIndices: vertices.toList()..sort(),
      area: area,
      averageNormal: normal.normalized,
      bounds: bounds,
      meanCurvature: meanCurvature,
      confidence: math.min(1, .55 + math.log(triangles.length + 1) / 15),
      health: RecognitionHealth.good,
    );
    final stability = _planarStability(
      mesh: mesh,
      seed: seed,
      accepted: accepted,
      normals: normals,
      adjacency: adjacency,
      tolerance: tolerance,
      normalLimit: settings.normalAngleDegrees * math.pi / 180,
      seedNeighborhood: settings.seedNeighborhoodTriangles,
    );
    return RegionGrowingResult(
      [region],
      RegionGraph({id: <String>{}}),
      diagnostics: {
        'mode': 'planar',
        'seedTriangle': seed,
        'visitedTriangles': visited.length,
        'selectedTriangles': triangles.length,
        'rejectedByDistance': rejectedByDistance,
        'rejectedByNormal': rejectedByNormal,
        'toleranceMm': tolerance,
        ...stability,
      },
    );
  }

  Map<String, Object?> _planarStability({
    required MeshSurfaceData mesh,
    required int seed,
    required Set<int> accepted,
    required List<Vector3> normals,
    required List<Set<int>> adjacency,
    required double tolerance,
    required double normalLimit,
    required int seedNeighborhood,
  }) {
    final targets = <int>{
      math.max(3, seedNeighborhood),
      math.max(6, seedNeighborhood * 2),
      math.max(12, seedNeighborhood * 4),
      math.max(24, seedNeighborhood * 8),
      accepted.length,
    }.toList()..sort();
    final maximum = math.min(
      mesh.triangles.length,
      math.max(targets.last, accepted.length * 2),
    );
    final visited = <int>{seed}, queue = <int>[seed];
    final samples = <Map<String, Object?>>[];
    final interiorSamples = <Map<String, Object?>>[];
    var targetIndex = 0;
    while (queue.isNotEmpty && visited.length <= maximum) {
      final current = queue.removeAt(0);
      final neighbors = adjacency[current].toList()..sort();
      for (final next in neighbors) {
        if (visited.length >= maximum) break;
        if (visited.add(next)) queue.add(next);
      }
      while (targetIndex < targets.length &&
          visited.length >= targets[targetIndex]) {
        final ids = visited.take(targets[targetIndex]).toSet();
        samples.add(
          _scaleSample(mesh, ids, normals, normals[seed], tolerance),
        );
        final interiorIds = ids.intersection(accepted);
        if (interiorIds.isNotEmpty) {
          interiorSamples.add(
            _scaleSample(mesh, interiorIds, normals, normals[seed], tolerance),
          );
        }
        targetIndex++;
      }
    }
    if (samples.isEmpty) {
      return const {
        'planarClassification': 'ambiguous',
        'planarStability': <Object?>[],
        'planarStabilityReason': 'insufficient-multiscale-samples',
      };
    }
    final first = interiorSamples.isEmpty ? samples.first : interiorSamples.first;
    final stabilitySamples =
        interiorSamples.isEmpty ? samples : interiorSamples;
    final stable = stabilitySamples.where((sample) {
      final rms = (sample['rms'] as num).toDouble();
      final maximum = (sample['maximum'] as num).toDouble();
      final drift = (sample['normalDriftRadians'] as num).toDouble();
      return rms <= tolerance && maximum <= tolerance && drift <= normalLimit;
    }).length;
    final hasStrongInstability = stabilitySamples.any((sample) {
      final rms = (sample['rms'] as num).toDouble();
      final maximum = (sample['maximum'] as num).toDouble();
      final drift = (sample['normalDriftRadians'] as num).toDouble();
      return rms > tolerance || maximum > tolerance || drift > normalLimit;
    });
    final finalScale = stabilitySamples.last;
    final finalScaleUnstable =
        (finalScale['rms'] as num).toDouble() > tolerance ||
        (finalScale['maximum'] as num).toDouble() > tolerance ||
        (finalScale['normalDriftRadians'] as num).toDouble() > normalLimit;
    final localValid = (first['rms'] as num).toDouble() <= tolerance &&
        (first['maximum'] as num).toDouble() <= tolerance;
    final boundary = _planarBoundaryEvidence(
      accepted: accepted,
      normals: normals,
      adjacency: adjacency,
      normalLimit: normalLimit,
    );
    final externalExpansionUnstable =
        (samples.last['triangleCount'] as int) !=
            (stabilitySamples.last['triangleCount'] as int) &&
        ((samples.last['rms'] as num).toDouble() > tolerance ||
            (samples.last['maximum'] as num).toDouble() > tolerance ||
            (samples.last['normalDriftRadians'] as num).toDouble() >
                normalLimit);
    final coherentMechanicalBoundary =
        (boundary['planarBoundaryTransitionEdges'] as int) >= 3 &&
            (boundary['planarBoundaryTransitionEdges'] as int) * 2 >=
                (boundary['planarBoundaryEdges'] as int);
    final largeEnoughForCad =
        accepted.length >= math.max(24, seedNeighborhood * 4);
    final classification = !localValid
        ? PlanarClassification.ambiguous
        : externalExpansionUnstable && !coherentMechanicalBoundary
        ? PlanarClassification.curvedPatch
        : finalScaleUnstable &&
                largeEnoughForCad &&
                !coherentMechanicalBoundary
        ? PlanarClassification.curvedPatch
        : externalExpansionUnstable &&
                coherentMechanicalBoundary &&
                !largeEnoughForCad
        ? PlanarClassification.localReference
        : hasStrongInstability && stable <= 1
        ? PlanarClassification.curvedPatch
        : stable >= 3 && !hasStrongInstability
        ? PlanarClassification.planarCadCandidate
        : PlanarClassification.localReference;
    return {
      'planarClassification': classification.name,
      'planarStableScales': stable,
      'planarScaleCount': samples.length,
      'planarInteriorStableScales': stable,
      'planarInteriorScaleCount': stabilitySamples.length,
      'planarStability': samples,
      'planarInteriorStability': stabilitySamples,
      ...boundary,
      'planarExternalExpansionUnstable': externalExpansionUnstable,
      'planarStabilityReason': hasStrongInstability
          ? 'instability-in-normal-or-residual-across-scales'
          : externalExpansionUnstable && coherentMechanicalBoundary
          ? 'stable-interior-with-coherent-mechanical-boundary'
          : 'local-fit-stable-at-observed-scales',
    };
  }

  Map<String, Object> _planarBoundaryEvidence({
    required Set<int> accepted,
    required List<Vector3> normals,
    required List<Set<int>> adjacency,
    required double normalLimit,
  }) {
    var boundaryEdges = 0;
    var boundaryTransitionEdges = 0;
    final externalTriangles = <int>{};
    for (final triangle in accepted) {
      for (final neighbor in adjacency[triangle]) {
        if (accepted.contains(neighbor)) continue;
        final pair = triangle < neighbor
            ? (triangle, neighbor)
            : (neighbor, triangle);
        if (!externalTriangles.add(pair.$2)) continue;
        boundaryEdges++;
        if (_orientedAngle(normals[triangle], normals[neighbor]) > normalLimit) {
          boundaryTransitionEdges++;
        }
      }
    }
    return {
      'planarBoundaryEdges': boundaryEdges,
      'planarBoundaryTransitionEdges': boundaryTransitionEdges,
      'planarExternalTriangles': externalTriangles.length,
    };
  }

  Map<String, Object?> _scaleSample(
    MeshSurfaceData mesh,
    Set<int> triangles,
    List<Vector3> normals,
    Vector3 referenceNormal,
    double tolerance,
  ) {
    final vertices = <int>{};
    var weightedNormal = Vector3.zero;
    var area = 0.0;
    for (final index in triangles) {
      final triangle = mesh.triangles[index];
      vertices.addAll([triangle.$1, triangle.$2, triangle.$3]);
      final a = _vertex(mesh, triangle.$1);
      final b = _vertex(mesh, triangle.$2);
      final c = _vertex(mesh, triangle.$3);
      final triangleArea = (b - a).cross(c - a).length * .5;
      area += triangleArea;
      weightedNormal = weightedNormal + normals[index] * triangleArea;
    }
    final points = vertices.map((id) => _vertex(mesh, id)).toList();
    final fit = const FittingEngine().fitPlane(points);
    final drift = referenceNormal.length <= 1e-12 ||
            weightedNormal.length <= 1e-12
        ? math.pi
        : _orientedAngle(referenceNormal, weightedNormal.normalized);
    return {
      'triangleCount': triangles.length,
      'area': area,
      'rms': fit.rmsError,
      'maximum': fit.maxError,
      'normalDriftRadians': drift,
      'withinTolerance': fit.rmsError <= tolerance && fit.maxError <= tolerance,
    };
  }

  Vector3 _vertex(MeshSurfaceData mesh, int index) {
    if (index < 0 || index >= mesh.vertices.length) return Vector3.zero;
    return mesh.vertices[index];
  }

  double _orientedAngle(Vector3 a, Vector3 b) =>
      math.acos(a.dot(b).clamp(-1.0, 1.0));

  List<Set<int>> _triangleAdjacency(List<(int, int, int)> triangles) {
    final edgeOwners = <(int, int), List<int>>{};
    for (var i = 0; i < triangles.length; i++) {
      final t = triangles[i];
      for (final edge in [(t.$1, t.$2), (t.$2, t.$3), (t.$3, t.$1)]) {
        final key = edge.$1 < edge.$2 ? edge : (edge.$2, edge.$1);
        edgeOwners.putIfAbsent(key, () => []).add(i);
      }
    }
    final result = List.generate(triangles.length, (_) => <int>{});
    for (final owners in edgeOwners.values) {
      for (final a in owners) {
        for (final b in owners) {
          if (a != b) result[a].add(b);
        }
      }
    }
    return result;
  }

  void _mergeSmall(
    List<Set<int>> groups,
    List<Set<int>> adjacency,
    int minimum,
  ) {
    final owner = <int, int>{};
    for (var group = 0; group < groups.length; group++) {
      for (final triangle in groups[group]) {
        owner[triangle] = group;
      }
    }
    final active = List<bool>.filled(groups.length, true);
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = groups.length - 1; i >= 0; i--) {
        if (!active[i] || groups[i].length >= minimum) continue;
        final contactsByGroup = <int, int>{};
        for (final triangle in groups[i]) {
          for (final neighbor in adjacency[triangle]) {
            final candidate = owner[neighbor];
            if (candidate != null && candidate != i && active[candidate]) {
              contactsByGroup[candidate] =
                  (contactsByGroup[candidate] ?? 0) + 1;
            }
          }
        }
        var best = -1, contacts = -1;
        final candidates = contactsByGroup.keys.toList()..sort();
        for (final j in candidates) {
          final count = contactsByGroup[j]!;
          if (count > contacts) {
            best = j;
            contacts = count;
          }
        }
        if (best >= 0 && contacts > 0) {
          groups[best].addAll(groups[i]);
          for (final triangle in groups[i]) {
            owner[triangle] = best;
          }
          groups[i].clear();
          active[i] = false;
          changed = true;
        }
      }
    }
    groups.removeWhere((group) => group.isEmpty);
  }

  double _angle(Vector3 a, Vector3 b) =>
      math.acos(a.dot(b).abs().clamp(-1.0, 1.0));
  String _color(int i) {
    const colors = [
      '#2196F3',
      '#F44336',
      '#4CAF50',
      '#FF9800',
      '#9C27B0',
      '#00BCD4',
      '#CDDC39',
      '#795548',
      '#E91E63',
      '#607D8B',
    ];
    return colors[i % colors.length];
  }

  KernelBounds _bounds(List<Vector3> p) {
    var minX = p.first.x,
        minY = p.first.y,
        minZ = p.first.z,
        maxX = minX,
        maxY = minY,
        maxZ = minZ;
    for (final v in p.skip(1)) {
      minX = math.min(minX, v.x);
      minY = math.min(minY, v.y);
      minZ = math.min(minZ, v.z);
      maxX = math.max(maxX, v.x);
      maxY = math.max(maxY, v.y);
      maxZ = math.max(maxZ, v.z);
    }
    return KernelBounds(minX, minY, minZ, maxX, maxY, maxZ);
  }
}
