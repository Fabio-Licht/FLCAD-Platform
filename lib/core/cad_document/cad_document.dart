import '../cad_kernel/io/kernel_io_models.dart';
import '../cad_kernel/models/kernel_models.dart';

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
  });
  final String id;
  final CadDocumentEntityKind kind;
  final Map<String, dynamic> data;
  final ShapeHandle? shape;
  final KernelMeshHandle? mesh;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'data': data,
    'shape': shape?.toJson(),
    'mesh': mesh == null ? null : _meshJson(mesh!),
  };

  factory CadDocumentEntity.fromJson(Map<String, dynamic> json) =>
      _fromJson(json);

  static CadDocumentEntity _fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(json['data'] as Map? ?? const {});
    final managed = data['managedBrepAssets'];
    final managedStl = data['managedStlAssets'];
    if (managed != null && managedStl != null) {
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
    return CadDocumentEntity(
      id: json['id'] as String,
      kind: CadDocumentEntityKind.values.byName(json['kind'] as String),
      data: data,
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
  static const version = 1;
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
    if (json['schema'] != schema) {
      throw const FormatException('Unsupported CAD document schema.');
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
}
