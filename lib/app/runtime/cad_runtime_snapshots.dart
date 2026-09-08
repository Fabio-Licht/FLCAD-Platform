part of 'cad_runtime.dart';

/// Weak identity marks: only this runtime's own recursively frozen objects are
/// reusable. No strong cache, public marker or consumer-supplied claim is trusted.
class _CadSnapshots {
  final Expando<bool> _owned = Expando<bool>('runtime frozen snapshot');
  final Expando<bool> _normalized = Expando<bool>('normalized snapshot');
  T _mark<T extends Object>(T value) {
    _owned[value] = true;
    return value;
  }

  bool isNormalized(CadDocument document) => _normalized[document] == true;

  // Even an owned entity crossing the public boundary is detached again.
  CadDocumentEntity captureEntity(CadDocumentEntity source) => _entity(
    CadDocumentEntity.fromJson(jsonDecode(jsonEncode(source.toJson()))),
  );

  Object? _json(Object? value, [Set<Object>? ancestors]) {
    if (value == null || value is String || value is bool) return value;
    if (value is num) {
      if (!value.isFinite) {
        jsonEncode(value); // Existing JSON rejection contract.
      }
      return value;
    }
    if (_owned[value] == true) return value;
    final visiting = ancestors ?? Set<Object>.identity();
    if (!visiting.add(value)) throw JsonCyclicError(value);
    try {
      if (value is Map<String, dynamic>) {
        return _mark(
          Map<String, dynamic>.unmodifiable({
            for (final e in value.entries) e.key: _json(e.value, visiting),
          }),
        );
      }
      if (value is List) {
        return _mark(
          List<dynamic>.unmodifiable(value.map((v) => _json(v, visiting))),
        );
      }
      // Match existing persistence for other values with a valid toJson contract.
      return _json(jsonDecode(jsonEncode(value)), visiting);
    } finally {
      visiting.remove(value);
    }
  }

  CadDocumentEntity _entity(CadDocumentEntity source) {
    if (_owned[source] == true) return source;
    final shape = source.shape, mesh = source.mesh;
    return _mark(
      CadDocumentEntity(
        id: source.id,
        kind: source.kind,
        data: _json(source.data) as Map<String, dynamic>,
        shape: shape == null
            ? null
            : ShapeHandle.reference(
                persistentId: shape.persistentId,
                kernelId: shape.kernelId,
                type: shape.type,
                revision: shape.revision,
                fingerprint: shape.fingerprint,
                metadata: _json(shape.metadata) as Map<String, dynamic>,
              ),
        mesh: mesh == null
            ? null
            : KernelMeshHandle(
                persistentId: mesh.persistentId,
                kernelId: mesh.kernelId,
                fingerprint: mesh.fingerprint,
                vertexCount: mesh.vertexCount,
                triangleCount: mesh.triangleCount,
                bounds: mesh.bounds,
                hasNormals: mesh.hasNormals,
                degenerateTriangleCount: mesh.degenerateTriangleCount,
                metadata: _json(mesh.metadata) as Map<String, dynamic>,
              ),
      ),
    );
  }

  CadDocument document(CadDocument source, {bool normalized = false}) {
    if (_owned[source] == true) {
      if (normalized) _normalized[source] = true;
      return source;
    }
    final result = _mark(
      CadDocument(
        projectId: source.projectId,
        entities: _mark(
          Map<String, CadDocumentEntity>.unmodifiable({
            for (final e in source.entities.entries) e.key: _entity(e.value),
          }),
        ),
        revisions: _mark(
          List<CadDocumentRevision>.unmodifiable(source.revisions),
        ),
        parameters: _json(source.parameters) as Map<String, dynamic>,
        officialExportShapeId: source.officialExportShapeId,
      ),
    );
    if (normalized) _normalized[result] = true;
    return result;
  }

  List<CadDocument> history(Iterable<CadDocument> source) =>
      List<CadDocument>.unmodifiable(source.map((value) => document(value)));
}
