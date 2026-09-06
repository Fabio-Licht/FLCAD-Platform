import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_kernel/precision/precision.dart';
import 'package:flcad_mobile/core/metric_reference/metric_reference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates an identifiable FLSCAN fiducial marker', () {
    final marker = fiducialMarker(
      id: 'Marker001',
      nominalSize: 25,
      material: FiducialMaterial.pvc,
    );

    expect(marker.hasValidChecksum, isTrue);
    expect(marker.id, 'Marker001');
    expect(marker.material, FiducialMaterial.pvc);
    expect(marker.toJson()['version'], '1');
  });

  test('supports official and custom scale bar sizes', () {
    expect(
      ScaleBar.calibrated(id: 'ScaleBar001', millimeters: 50).size,
      ScaleBarSize.mm50,
    );
    expect(
      ScaleBar.calibrated(id: 'ScaleBarCustom', millimeters: 75).size,
      ScaleBarSize.custom,
    );
    expect(
      () => ScaleBar.calibrated(id: 'Invalid', millimeters: 0),
      throwsArgumentError,
    );
  });

  test('combines marker, scale bar and known distance in one solver', () {
    final system = MetricReferenceSystem();
    final capturedAt = DateTime.utc(2026, 8, 22);
    system.add(
      fiducialMarker(id: 'Marker001', nominalSize: 20).toReference(
        pointA: Vector3.zero,
        pointB: const Vector3(10, 0, 0),
        measuredSize: 10,
        capturedAt: capturedAt,
      ),
    );
    system.add(
      ScaleBar.calibrated(id: 'ScaleBar001', millimeters: 100).toReference(
        pointA: Vector3.zero,
        pointB: const Vector3(50, 0, 0),
        capturedAt: capturedAt,
      ),
    );
    system.add(
      MetricReference(
        id: 'KnownDistance001',
        type: MetricReferenceType.distance,
        pointA: Vector3.zero,
        pointB: const Vector3(5, 0, 0),
        knownValue: 10,
        unit: LengthUnit.millimeter,
        createdAt: capturedAt,
      ),
    );

    final solution = system.solve();
    final graph = system.evidenceGraph();

    expect(system.references, hasLength(3));
    expect(solution.references, hasLength(3));
    expect(solution.evidence, hasLength(3));
    expect(graph.nodes.where((node) => node.kind == EvidenceNodeKind.metricReference),
        hasLength(3));
    expect(graph.edges, hasLength(3));
  });

  test('automatic recognition accepts device-neutral observations', () {
    final system = MetricReferenceSystem();
    final observation = MetricReferenceObservation(
      id: 'ReferenceSphere001',
      origin: MetricReferenceOrigin.referenceObject,
      type: MetricReferenceType.diameter,
      pointA: Vector3.zero,
      pointB: const Vector3(10, 0, 0),
      nominalValue: 20,
      unit: LengthUnit.millimeter,
      metadata: const {'shape': 'sphere'},
    );

    system.recognize([observation], capturedAt: DateTime.utc(2026, 8, 22));

    expect(system.references.single.origin, MetricReferenceOrigin.referenceObject);
    expect(system.references.single.metadata['shape'], 'sphere');
  });
}
