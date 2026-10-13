import 'dart:math' as math;

import '../../../core/cad_document/cad_document.dart';
import '../../../core/geometric_kernel/geometry/primitives.dart';
import '../../../core/geometric_kernel/geometry/vectors.dart';
import '../../runtime/cad_runtime.dart';
import 'mesh_bvh.dart';
import 'mesh_section_kernel.dart';

class SectionManager {
  const SectionManager(this.runtime);
  final CadRuntime runtime;
  static const _maxDisplaySegments = 1000;

  List<CadDocumentEntity> get sections =>
      runtime.document?.entities.values
          .where((entity) => entity.kind == CadDocumentEntityKind.section)
          .toList() ??
      const [];

  Future<CadDocumentEntity> create({
    required String planeId,
    required Vector3 origin,
    required Vector3 normal,
    String? meshId,
    String? name,
    double absoluteTolerance = 1e-9,
    double relativeTolerance = 1e-10,
  }) async {
    final managedFallback = runtime.document?.entities.values
        .where((entity) => entity.data['managedStlAssets'] is Map)
        .singleOrNull;
    final managedMeshId =
        meshId ?? runtime.activeImport?.id ?? managedFallback?.id;
    final geometry =
        managedMeshId != null &&
            runtime.document?.entities[managedMeshId]?.data['managedStlAssets']
                is Map
        ? await runtime.managedMeshGeometryFor(managedMeshId)
        : runtime.activeMeshGeometry;
    if (geometry == null) {
      throw StateError(
        'Import or select a managed STL before creating a Section.',
      );
    }
    final meshEntity = managedMeshId == null
        ? null
        : runtime.document?.entities[managedMeshId];
    if (meshEntity == null) {
      throw StateError('The selected STL has no durable mesh entity.');
    }
    final bvh = runtime.readOrCreate<MeshBvh>(
      'sections.meshBvh',
      () => MeshBvh(geometry),
    );
    final result = ProfessionalMeshSectionKernel(bvh).intersect(
      plane: Plane3(origin, normal),
      tolerance: MeshSectionTolerance(
        absolute: absoluteTolerance,
        relative: relativeTolerance,
      ),
    );
    var sequence = 1;
    final used = sections.map((entity) => entity.id).toSet();
    while (used.contains(
      'ReferenceCurve${sequence.toString().padLeft(3, '0')}',
    )) {
      sequence++;
    }
    final id = 'ReferenceCurve${sequence.toString().padLeft(3, '0')}';
    final entity = _entity(
      id: id,
      name: name ?? id,
      planeId: planeId,
      meshId: meshEntity.id,
      origin: origin,
      normal: normal.normalized,
      result: result,
      absoluteTolerance: absoluteTolerance,
      relativeTolerance: relativeTolerance,
    );
    await runtime.mutate(command: 'section.create', upsert: [entity]);
    runtime.select({id});
    return runtime.document!.entities[id]!;
  }

  Future<CadDocumentEntity> updateOffset(String id, double offset) async {
    final source =
        runtime.document?.entities[id] ??
        (throw StateError('Unknown Section: $id'));
    final definition = Map<String, dynamic>.from(source.data['section'] as Map);
    final origin = Vector3.fromJson(definition['origin'] as List);
    final normal = Vector3.fromJson(definition['normal'] as List).normalized;
    return createReplacement(
      source,
      origin: origin + normal * offset,
      normal: normal,
      command: 'section.update',
    );
  }

  Future<CadDocumentEntity> createReplacement(
    CadDocumentEntity source, {
    required Vector3 origin,
    required Vector3 normal,
    required String command,
  }) async {
    final definition = Map<String, dynamic>.from(source.data['section'] as Map);
    final geometry =
        runtime.activeMeshGeometry ??
        (throw StateError('The Section mesh is unavailable.'));
    final bvh = runtime.readOrCreate<MeshBvh>(
      'sections.meshBvh',
      () => MeshBvh(geometry),
    );
    final absolute = (definition['absoluteTolerance'] as num).toDouble();
    final relative = (definition['relativeTolerance'] as num).toDouble();
    final result = ProfessionalMeshSectionKernel(bvh).intersect(
      plane: Plane3(origin, normal),
      tolerance: MeshSectionTolerance(absolute: absolute, relative: relative),
    );
    final replacement = _entity(
      id: source.id,
      name: source.data['name'] as String,
      planeId: definition['planeId'] as String,
      meshId: definition['meshId'] as String,
      origin: origin,
      normal: normal,
      result: result,
      absoluteTolerance: absolute,
      relativeTolerance: relative,
      revision: ((source.data['revision'] as num?)?.toInt() ?? 1) + 1,
    );
    await runtime.mutate(command: command, upsert: [replacement]);
    return runtime.document!.entities[source.id]!;
  }

  Future<CadDocumentEntity> setOffset(String id, double offset) async {
    final source =
        runtime.document?.entities[id] ??
        (throw StateError('Unknown Reference Curve: $id'));
    final definition = Map<String, dynamic>.from(source.data['section'] as Map);
    final base = Vector3.fromJson(
      (definition['baseOrigin'] as List?) ?? definition['origin'] as List,
    );
    final normal = Vector3.fromJson(definition['normal'] as List).normalized;
    return createReplacement(
      source,
      origin: base + normal * offset,
      normal: normal,
      command: 'reference-curve.dynamic-update',
    );
  }

  Future<CadDocumentEntity> recalculate(String id) async {
    final source =
        runtime.document?.entities[id] ??
        (throw StateError('Unknown Reference Curve: $id'));
    final definition = Map<String, dynamic>.from(source.data['section'] as Map);
    return createReplacement(
      source,
      origin: Vector3.fromJson(definition['origin'] as List),
      normal: Vector3.fromJson(definition['normal'] as List),
      command: 'reference-curve.recalculate',
    );
  }

  Future<void> setDisplayMode(String id, String mode) async {
    if (!const {'curveOnly', 'curveAndMesh', 'highlighted'}.contains(mode)) {
      throw ArgumentError.value(mode, 'mode');
    }
    final source =
        runtime.document?.entities[id] ??
        (throw StateError('Unknown Reference Curve: $id'));
    final geometry = Map<String, dynamic>.from(
      source.data['sceneGeometry'] as Map,
    );
    geometry['displayColor'] = mode == 'highlighted'
        ? 'referenceCurveHighlight'
        : 'referenceCurve';
    geometry['strokeWidth'] = mode == 'highlighted' ? 3.0 : 1.35;
    await runtime.mutate(
      command: 'reference-curve.display',
      upsert: [
        CadDocumentEntity(
          id: source.id,
          kind: source.kind,
          data: {
            ...source.data,
            'displayMode': mode,
            'sceneGeometry': geometry,
          },
        ),
      ],
    );
    final meshId = (source.data['section'] as Map)['meshId'] as String?;
    if (meshId != null && runtime.document?.entities[meshId] != null) {
      await runtime.setEntityVisibility(meshId, mode != 'curveOnly');
    }
  }

  Future<List<CadDocumentEntity>> createMultiple({
    required String planeId,
    required Vector3 origin,
    required Vector3 normal,
    required int count,
    required double spacing,
  }) async {
    if (count < 1) throw ArgumentError.value(count, 'count');
    final output = <CadDocumentEntity>[];
    final first = -(count - 1) * spacing / 2;
    for (var index = 0; index < count; index++) {
      output.add(
        await create(
          planeId: planeId,
          origin: origin + normal.normalized * (first + index * spacing),
          normal: normal,
        ),
      );
    }
    return output;
  }

  Future<void> rename(String id, String name) async {
    final source =
        runtime.document?.entities[id] ??
        (throw StateError('Unknown Section: $id'));
    await runtime.mutate(
      command: 'section.rename',
      upsert: [
        CadDocumentEntity(
          id: source.id,
          kind: source.kind,
          data: {...source.data, 'name': name.trim()},
        ),
      ],
    );
  }

  Future<void> remove(String id) =>
      runtime.removeEntity(id, command: 'section.delete');
  Future<void> visibility(String id, bool visible) =>
      runtime.setEntityVisibility(id, visible);

  CadDocumentEntity _entity({
    required String id,
    required String name,
    required String planeId,
    required String meshId,
    required Vector3 origin,
    required Vector3 normal,
    required MeshSectionResult result,
    required double absoluteTolerance,
    required double relativeTolerance,
    int revision = 1,
  }) {
    final segments = result.segments
        .map((segment) => [segment.a.toJson(), segment.b.toJson()])
        .toList();
    final length = result.segments.fold<double>(
      0,
      (total, segment) => total + segment.a.distanceTo(segment.b),
    );
    final topology = _topology(result.segments, normal);
    final displaySegments = _displaySegments(segments);
    return CadDocumentEntity(
      id: id,
      kind: CadDocumentEntityKind.section,
      data: {
        'name': name,
        'referenceCurve': true,
        'authoringRoot': true,
        'authoringWorkspace': 'Sections',
        'group': 'Reference Curves',
        'references': [planeId, meshId],
        'dependencies': [planeId, meshId],
        'displayMode': 'curveAndMesh',
        'dynamicUpdate': true,
        'revision': revision,
        'sceneKind': 'curve',
        'sceneVisible': true,
        'sceneGeometry': {
          // Keep the exact section in `section.segments`; this bounded
          // presentation prevents a dense STL intersection from blocking the
          // Flutter overlay when it is selected or highlighted.
          'segments': displaySegments,
          'referenceCurve': true,
          'displayColor': 'referenceCurve',
          'strokeWidth': 1.35,
        },
        'section': {
          'planeId': planeId,
          'meshId': meshId,
          'origin': origin.toJson(),
          'baseOrigin': revision == 1
              ? origin.toJson()
              : ((runtime.document?.entities[id]?.data['section']
                        as Map?)?['baseOrigin'] ??
                    origin.toJson()),
          'offset': revision == 1
              ? 0.0
              : (() {
                  final baseRaw =
                      (runtime.document?.entities[id]?.data['section']
                              as Map?)?['baseOrigin']
                          as List?;
                  if (baseRaw == null) return 0.0;
                  return (origin - Vector3.fromJson(baseRaw)).dot(normal);
                })(),
          'normal': normal.toJson(),
          'segments': segments,
          'length': length,
          'segmentCount': result.segments.length,
          'pointCount': result.points.length,
          'loopCount': topology.$1,
          'closed': topology.$2,
          'open': !topology.$2,
          'projectedArea': topology.$3,
          'absoluteTolerance': absoluteTolerance,
          'relativeTolerance': relativeTolerance,
          'toleranceUsed':
              result.segments.firstOrNull?.tolerance ??
              math.max(absoluteTolerance, relativeTolerance),
          'candidateTriangles': result.diagnostics.candidateTriangles,
          'degenerations': result.diagnostics.degenerateCount,
          'coplanarTriangles': result.diagnostics.coplanarTriangleCount,
          'nonManifoldEdges': result.diagnostics.nonManifoldEdgeCount,
          'elapsedMicroseconds': result.diagnostics.elapsed.inMicroseconds,
        },
      },
    );
  }

  List<List<List<double>>> _displaySegments(List<List<List<double>>> segments) {
    if (segments.length <= _maxDisplaySegments) return segments;
    final stride = (segments.length / _maxDisplaySegments).ceil();
    final output = <List<List<double>>>[];
    // Decimate by retaining complete source segments. Joining the first point
    // of one segment to the last point of a later segment invents diagonals
    // between disconnected STL intersections and can visibly cross loops.
    for (var start = 0; start < segments.length; start += stride) {
      output.add(segments[start]);
    }
    if (output.isNotEmpty && !identical(output.last, segments.last)) {
      output.add(segments.last);
    }
    return output;
  }

  (int, bool, double) _topology(List<SectionSegment> segments, Vector3 normal) {
    if (segments.isEmpty) return (0, false, 0);
    final tolerance = segments.first.tolerance;
    String key(Vector3 p) =>
        '${(p.x / tolerance).round()}:${(p.y / tolerance).round()}:${(p.z / tolerance).round()}';
    final adjacency = <String, List<String>>{};
    final points = <String, Vector3>{};
    for (final segment in segments) {
      final a = key(segment.a), b = key(segment.b);
      points[a] = segment.a;
      points[b] = segment.b;
      (adjacency[a] ??= []).add(b);
      (adjacency[b] ??= []).add(a);
    }
    final unvisited = adjacency.keys.toSet();
    var loops = 0, area = 0.0;
    var allClosed = true;
    final xAxis = normal
        .cross(
          normal.z.abs() < .9 ? const Vector3(0, 0, 1) : const Vector3(0, 1, 0),
        )
        .normalized;
    final yAxis = normal.cross(xAxis).normalized;
    while (unvisited.isNotEmpty) {
      final seed = unvisited.first;
      final component = <String>{}, pending = <String>[seed];
      while (pending.isNotEmpty) {
        final value = pending.removeLast();
        if (!component.add(value)) continue;
        pending.addAll(
          adjacency[value]!.where((item) => !component.contains(item)),
        );
      }
      unvisited.removeAll(component);
      final closed = component.every((item) => adjacency[item]!.length == 2);
      if (!closed) {
        allClosed = false;
        continue;
      }
      loops++;
      final ordered = <String>[seed];
      String? previous;
      var current = seed;
      while (true) {
        final next = adjacency[current]!.firstWhere(
          (item) => item != previous,
          orElse: () => seed,
        );
        if (next == seed) break;
        ordered.add(next);
        previous = current;
        current = next;
        if (ordered.length > component.length) break;
      }
      var twiceArea = 0.0;
      for (var index = 0; index < ordered.length; index++) {
        final a = points[ordered[index]]!;
        final b = points[ordered[(index + 1) % ordered.length]]!;
        final ax = a.dot(xAxis), ay = a.dot(yAxis);
        final bx = b.dot(xAxis), by = b.dot(yAxis);
        twiceArea += ax * by - bx * ay;
      }
      area += twiceArea.abs() / 2;
    }
    return (loops, allClosed, area);
  }
}
