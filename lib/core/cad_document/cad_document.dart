import '../cad_kernel/io/kernel_io_models.dart';
import '../cad_kernel/models/kernel_models.dart';
import 'managed_step_contract.dart';
import 'managed_cad_reference.dart';
import 'plane_axis_intersection_point.dart';
import 'alignment_coordinate_system.dart';
import 'entity_placement.dart';

enum CadDocumentEntityKind {
  collection,
  import,
  reference,
  curve,
  boundary,
  vertex,
  edge,
  wire,
  face,
  shell,
  solid,
  section,
  sketch,
  constraint,
  surface,
  recognition,
}

class CadDocumentEntity {
  const CadDocumentEntity({
    required this.id,
    required this.kind,
    required this.data,
    this.shape,
    this.mesh,
    this.placement,
  });
  final String id;
  final CadDocumentEntityKind kind;
  final Map<String, dynamic> data;
  final ShapeHandle? shape;
  final KernelMeshHandle? mesh;
  final EntityPlacement? placement;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'data': data,
    'shape': shape?.toJson(),
    'mesh': mesh == null ? null : _meshJson(mesh!),
    if (placement != null) 'placement': placement!.toJson(),
  };

  factory CadDocumentEntity.fromJson(Map<String, dynamic> json) =>
      _fromJson(json);

  static CadDocumentEntity _fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(json['data'] as Map? ?? const {});
    final managed = data['managedBrepAssets'];
    final managedStl = data['managedStlAssets'];
    final managedStep = data['managedStepAssets'];
    final rawPlacement = json['placement'];
    if (json.containsKey('placement') &&
        (rawPlacement is! Map ||
            json['kind'] != 'import' ||
            [managed, managedStl, managedStep].whereType<Map>().length != 1 ||
            json['shape'] != null ||
            json['mesh'] != null ||
            data['transformMatrix'] != null ||
            data['alignmentMatrix'] != null)) {
      throw const FormatException('Placement requires managed original assets');
    }
    if ([managed, managedStl, managedStep].where((v) => v != null).length > 1) {
      throw const FormatException('Ambiguous managed geometry asset reference');
    }
    if (managed != null) {
      // The asset object is a strict durable-document contract. Import here
      // avoids defaults during open/snapshot/Undo reconstruction.
      _validateManagedBrepAssets(Map<String, dynamic>.from(managed as Map));
    }
    if (managedStl != null) {
      _validateManagedStlAssets(Map<String, dynamic>.from(managedStl as Map));
    }
    if (managedStep != null) {
      final hasSemanticIdentity =
          data.containsKey('cadSemanticKind') ||
          data.containsKey('cadVisualType') ||
          data.containsKey('stepTechnicalName');
      if (managedStep is! Map ||
          json['shape'] != null ||
          json['mesh'] != null ||
          json['kind'] != 'import' ||
          data['format'] != 'step' ||
          data['sceneKind'] != 'mesh' ||
          data['name'] is! String ||
          (hasSemanticIdentity &&
              (data['stepTechnicalName'] is! String ||
                  data['cadSemanticKind'] is! String ||
                  !{'solid', 'surface'}.contains(data['cadSemanticKind']) ||
                  data['cadVisualType'] is! String)) ||
          (data.containsKey('sceneVisible') && data['sceneVisible'] is! bool) ||
          _hasStepTransientData(data) ||
          data.keys.any(
            (k) => !{
              'name',
              'format',
              if (hasSemanticIdentity) 'cadSemanticKind',
              if (hasSemanticIdentity) 'cadVisualType',
              if (hasSemanticIdentity) 'stepTechnicalName',
              'collectionId',
              'sceneKind',
              'managedStepAssets',
              'featureLifecycle',
              'sceneVisible',
              'alignmentByCoordinateSystem',
            }.contains(k),
          )) {
        throw const FormatException('Invalid managed STEP document entity');
      }
      validateManagedStepAssets(Map<String, dynamic>.from(managedStep));
    } else if (data['appearanceManifestAssetId'] != null ||
        data['appearanceManifest'] != null) {
      throw const FormatException(
        'STEP appearance requires managed STEP assets',
      );
    }
    final alignmentPlacement = data['alignmentByCoordinateSystem'];
    if (alignmentPlacement != null) {
      _validateAlignmentByCoordinateSystem(alignmentPlacement);
    }
    final managedReference = data[ManagedCadReference.dataKey];
    if (managedReference != null) {
      if (json['kind'] != CadDocumentEntityKind.reference.name ||
          json['shape'] != null ||
          json['mesh'] != null ||
          managedReference is! Map) {
        throw const FormatException('Invalid managed CAD reference entity');
      }
      ManagedCadReference.fromJson(Map<String, dynamic>.from(managedReference));
    }
    final intersection = data[PlaneAxisIntersectionPoint.dataKey];
    if (intersection != null) {
      if (json['kind'] != CadDocumentEntityKind.reference.name ||
          json['shape'] != null ||
          json['mesh'] != null ||
          data['sceneKind'] != 'point' ||
          intersection is! Map) {
        throw const FormatException(
          'Invalid plane-axis intersection point entity',
        );
      }
      PlaneAxisIntersectionPoint.fromJson(
        Map<String, dynamic>.from(intersection),
      );
    }
    final alignment = data[AlignmentCoordinateSystem.dataKey];
    if (alignment != null) {
      if (json['kind'] != CadDocumentEntityKind.reference.name ||
          json['shape'] != null ||
          json['mesh'] != null ||
          data['sceneKind'] != 'coordinateSystem' ||
          alignment is! Map) {
        throw const FormatException(
          'Invalid alignment coordinate system entity',
        );
      }
      AlignmentCoordinateSystem.fromJson(Map<String, dynamic>.from(alignment));
    }
    return CadDocumentEntity(
      id: json['id'] as String,
      kind: CadDocumentEntityKind.values.byName(json['kind'] as String),
      data: data,
      placement: rawPlacement == null
          ? null
          : EntityPlacement.fromJson(
              Map<String, dynamic>.from(rawPlacement as Map),
            ),
      shape: json['shape'] == null
          ? null
          : ShapeHandle.fromJson(
              Map<String, dynamic>.from(json['shape'] as Map),
            ),
      mesh: json['mesh'] == null
          ? null
          : _meshFromJson(Map<String, dynamic>.from(json['mesh'] as Map)),
    );
  }

  static void _validateAlignmentByCoordinateSystem(Object raw) {
    if (raw is! Map ||
        raw.length != 7 ||
        raw['schema'] != 'flcad.alignment-by-coordinate-system' ||
        raw['version'] != 1 ||
        raw['coordinateSystemId'] is! String ||
        raw['sourceEntityId'] is! String ||
        !{'original', 'workingCopy'}.contains(raw['mode']) ||
        raw['rotation'] is! List ||
        raw['translation'] is! List) {
      throw const FormatException('Invalid alignment placement contract');
    }
    final rotation = raw['rotation'] as List;
    final translation = raw['translation'] as List;
    if (rotation.length != 9 ||
        translation.length != 3 ||
        [
          ...rotation,
          ...translation,
        ].any((value) => value is! num || !value.isFinite)) {
      throw const FormatException('Invalid alignment placement values');
    }
  }

  static bool _hasStepTransientData(Object? value, [int depth = 0]) {
    if (depth > 64) return true;
    if (value is Map) {
      return value.entries.any(
        (e) =>
            const {
              'token',
              'pointer',
              'capability',
              'pathname',
              'sourcePath',
              'registeredPath',
              'ShapeHandle',
              'KernelMeshHandle',
              'fingerprint',
            }.contains(e.key) ||
            _hasStepTransientData(e.value, depth + 1),
      );
    }
    if (value is List) {
      return value.any((v) => _hasStepTransientData(v, depth + 1));
    }
    return false;
  }

  static void _validateManagedBrepAssets(Map<String, dynamic> value) {
    if (value.keys.toSet().difference(const {
          'schema',
          'version',
          'shapeAssetId',
          'displayMeshAssetId',
          'shapeSha256',
          'displayMeshSha256',
          'meshOnly',
        }).isNotEmpty ||
        value.length != 7 ||
        value['schema'] != 'flcad.managed-brep-assets' ||
        value['version'] != 1 ||
        value['meshOnly'] != false ||
        value['shapeAssetId'] is! Map ||
        value['displayMeshAssetId'] is! Map ||
        value['shapeSha256'] is! String ||
        value['displayMeshSha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['shapeSha256'] as String) ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(value['displayMeshSha256'] as String)) {
      throw const FormatException('Invalid managed BREP asset reference');
    }
    // Keep this core model independent of the runtime asset implementation,
    // while enforcing its serializable identity schema exactly.
    for (final key in ['shapeAssetId', 'displayMeshAssetId']) {
      final id = Map<String, dynamic>.from(value[key] as Map);
      if (id['schema'] != 'flcad.geometry-asset' ||
          id['version'] != 1 ||
          id['id'] is! String ||
          !RegExp(r'^ga1_[0-9a-f]{32}$').hasMatch(id['id'] as String)) {
        throw const FormatException('Invalid managed BREP asset ID');
      }
    }
  }

  static void _validateManagedStlAssets(Map<String, dynamic> value) {
    if (value.keys.toSet().difference(const {
          'schema',
          'version',
          'displayMeshAssetId',
          'displayMeshSha256',
          'meshOnly',
        }).isNotEmpty ||
        value.length != 5 ||
        value['schema'] != 'flcad.managed-stl-assets' ||
        value['version'] != 1 ||
        value['meshOnly'] != true ||
        value['displayMeshAssetId'] is! Map ||
        value['displayMeshSha256'] is! String ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(value['displayMeshSha256'] as String)) {
      throw const FormatException('Invalid managed STL asset reference');
    }
    final id = Map<String, dynamic>.from(value['displayMeshAssetId'] as Map);
    if (id.length != 3 ||
        id['schema'] != 'flcad.geometry-asset' ||
        id['version'] != 1 ||
        id['id'] is! String ||
        !RegExp(r'^ga1_[0-9a-f]{32}$').hasMatch(id['id'] as String)) {
      throw const FormatException('Invalid managed STL asset ID');
    }
  }

  static Map<String, dynamic> _meshJson(KernelMeshHandle value) => {
    'persistentId': value.persistentId,
    'kernelId': value.kernelId,
    'fingerprint': value.fingerprint,
    'vertexCount': value.vertexCount,
    'triangleCount': value.triangleCount,
    'bounds': value.bounds.toJson(),
    'hasNormals': value.hasNormals,
    'degenerateTriangleCount': value.degenerateTriangleCount,
    'metadata': value.metadata,
  };

  static KernelMeshHandle _meshFromJson(Map<String, dynamic> json) {
    final bounds = Map<String, dynamic>.from(json['bounds'] as Map);
    final minimum = (bounds['min'] as List).cast<num>();
    final maximum = (bounds['max'] as List).cast<num>();
    return KernelMeshHandle(
      persistentId: json['persistentId'] as String,
      kernelId: json['kernelId'] as String,
      fingerprint: json['fingerprint'] as String,
      vertexCount: json['vertexCount'] as int,
      triangleCount: json['triangleCount'] as int,
      bounds: KernelBounds(
        minimum[0].toDouble(),
        minimum[1].toDouble(),
        minimum[2].toDouble(),
        maximum[0].toDouble(),
        maximum[1].toDouble(),
        maximum[2].toDouble(),
      ),
      hasNormals: json['hasNormals'] as bool,
      degenerateTriangleCount: json['degenerateTriangleCount'] as int? ?? 0,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? const {}),
    );
  }
}

class CadDocumentRevision {
  const CadDocumentRevision(this.number, this.command, this.timestamp);
  final int number;
  final String command;
  final DateTime timestamp;
  Map<String, dynamic> toJson() => {
    'number': number,
    'command': command,
    'timestamp': timestamp.toUtc().toIso8601String(),
  };
  factory CadDocumentRevision.fromJson(Map<String, dynamic> json) =>
      CadDocumentRevision(
        json['number'] as int,
        json['command'] as String,
        DateTime.parse(json['timestamp'] as String),
      );
}

enum OfficialExportAction { keep, set, clear }

class OfficialExportUpdate {
  const OfficialExportUpdate.keep()
    : action = OfficialExportAction.keep,
      id = null;
  const OfficialExportUpdate.set(String value)
    : action = OfficialExportAction.set,
      id = value;
  const OfficialExportUpdate.clear()
    : action = OfficialExportAction.clear,
      id = null;
  final OfficialExportAction action;
  final String? id;
  String? resolve(String? previous) => switch (action) {
    OfficialExportAction.keep => previous,
    OfficialExportAction.set => id,
    OfficialExportAction.clear => null,
  };
}

class CadDocument {
  const CadDocument({
    required this.projectId,
    required this.entities,
    required this.revisions,
    required this.parameters,
    this.officialExportShapeId,
  });
  static const schema = 'flcad.cad-document';
  static const version = 2;
  final String projectId;
  final Map<String, CadDocumentEntity> entities;
  final List<CadDocumentRevision> revisions;
  final Map<String, dynamic> parameters;
  final String? officialExportShapeId;

  int get revision => revisions.length;
  ShapeHandle? get officialExportShape {
    final entity = entities[officialExportShapeId];
    return entity?.data['deleted'] == true ? null : entity?.shape;
  }

  factory CadDocument.empty(String projectId) => CadDocument(
    projectId: projectId,
    entities: const {},
    revisions: const [],
    parameters: const {},
  );

  CadDocument mutate({
    required String command,
    Iterable<CadDocumentEntity> upsert = const [],
    Iterable<String> remove = const [],
    OfficialExportUpdate officialExport = const OfficialExportUpdate.keep(),
  }) {
    final next = Map<String, CadDocumentEntity>.from(entities);
    for (final id in remove) {
      next.remove(id);
    }
    for (final entity in upsert) {
      next[entity.id] = entity;
    }
    final requestedExport = officialExport.resolve(officialExportShapeId);
    if (officialExport.action == OfficialExportAction.set) {
      final entity = next[requestedExport];
      // ExportValidation rejects temporary handles. Geometric diagnostics remain
      // the export engine's responsibility; this documentary update does no IO.
      if (entity == null ||
          entity.data['deleted'] == true ||
          entity.shape == null ||
          entity.shape!.metadata['temporary'] == true) {
        throw StateError('Invalid official export target: $requestedExport');
      }
    }
    return CadDocument(
      projectId: projectId,
      entities: Map.unmodifiable(next),
      revisions: List.unmodifiable([
        ...revisions,
        CadDocumentRevision(revision + 1, command, DateTime.now()),
      ]),
      parameters: parameters,
      officialExportShapeId: requestedExport,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'version': version,
    'projectId': projectId,
    'entities': entities.values.map((value) => value.toJson()).toList(),
    'revisions': revisions.map((value) => value.toJson()).toList(),
    'parameters': parameters,
    'officialExportShapeId': officialExportShapeId,
  };

  factory CadDocument.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema ||
        json['version'] is! int ||
        !const [1, 2].contains(json['version'])) {
      throw const FormatException('Unsupported CAD document schema.');
    }
    if (json['version'] == 1 &&
        (json['entities'] as List? ?? const []).any(
          (e) => e is Map && e.containsKey('placement'),
        )) {
      throw const FormatException('Placement requires CAD document version 2');
    }
    final entities = (json['entities'] as List? ?? const [])
        .map(
          (value) => CadDocumentEntity.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList();
    return CadDocument(
      projectId: json['projectId'] as String,
      entities: Map.unmodifiable({
        for (final value in entities) value.id: value,
      }),
      revisions: (json['revisions'] as List? ?? const [])
          .map(
            (value) => CadDocumentRevision.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(),
      parameters: Map<String, dynamic>.from(
        json['parameters'] as Map? ?? const {},
      ),
      officialExportShapeId: json['officialExportShapeId'] as String?,
    );
  }

  /// Copy used when a command mutates the live document and then throws.
  /// Nested maps and lists are copied. Shape and mesh handles stay shared
  /// because their native kernel objects are not owned by this snapshot.
  /// [ShapeHandle.metadata] is unmodifiable, so an in-place metadata write is
  /// rejected by the handle itself. This copy does not restore native geometry.
  CadDocument detachedCheckpoint() => CadDocument(
    projectId: projectId,
    entities: Map.unmodifiable({
      for (final entity in entities.values)
        entity.id: CadDocumentEntity(
          id: entity.id,
          kind: entity.kind,
          data: _detachSnapshotValue(entity.data)! as Map<String, dynamic>,
          shape: entity.shape,
          mesh: entity.mesh,
          placement: entity.placement,
        ),
    }),
    revisions: List<CadDocumentRevision>.unmodifiable(revisions),
    parameters: _detachSnapshotValue(parameters)! as Map<String, dynamic>,
    officialExportShapeId: officialExportShapeId,
  );
}

Object? _detachSnapshotValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': _detachSnapshotValue(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _detachSnapshotValue(item)];
  }
  return value;
}
