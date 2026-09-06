import '../../acquisition_intelligence/models/evidence_graph.dart';
import '../../geometric_kernel/geometry/vectors.dart';
import '../../geometric_kernel/precision/precision.dart';
import '../models/metric_reference.dart';
import '../models/reference_families.dart';
import 'metric_reference_solver.dart';

class MetricReferenceObservation {
  const MetricReferenceObservation({
    required this.id,
    required this.origin,
    required this.pointA,
    required this.pointB,
    required this.nominalValue,
    required this.unit,
    this.type = MetricReferenceType.distance,
    this.confidence = 1,
    this.metadata = const {},
  });

  final String id;
  final MetricReferenceOrigin origin;
  final MetricReferenceType type;
  final Vector3 pointA;
  final Vector3 pointB;
  final double nominalValue;
  final LengthUnit unit;
  final double confidence;
  final Map<String, dynamic> metadata;

  MetricReference toReference({DateTime? capturedAt}) => MetricReference(
    id: id,
    type: type,
    origin: origin,
    pointA: pointA,
    pointB: pointB,
    knownValue: nominalValue,
    unit: unit,
    createdAt: capturedAt ?? DateTime.now().toUtc(),
    uncertainty: (1 - confidence.clamp(0.0, 1.0)) * nominalValue,
    metadata: metadata,
  );
}

abstract interface class MetricReferenceRecognizer {
  List<MetricReferenceObservation> recognize(Object frame);
}

class AutomaticMetricReferenceRecognizer implements MetricReferenceRecognizer {
  const AutomaticMetricReferenceRecognizer();

  @override
  List<MetricReferenceObservation> recognize(Object frame) =>
      frame is Iterable<MetricReferenceObservation>
      ? List.unmodifiable(frame)
      : const [];
}

class MetricReferenceSystem {
  MetricReferenceSystem({
    MetricReferenceSolver solver = const MetricReferenceSolver(),
    MetricReferenceRecognizer recognizer =
        const AutomaticMetricReferenceRecognizer(),
  }) : _solver = solver,
       _recognizer = recognizer;

  final MetricReferenceSolver _solver;
  final MetricReferenceRecognizer _recognizer;
  final List<MetricReference> _references = [];

  List<MetricReference> get references => List.unmodifiable(_references);

  void add(MetricReference reference) {
    if (_references.any((item) => item.id == reference.id)) {
      throw StateError('Metric reference ${reference.id} already exists');
    }
    _references.add(reference);
  }

  void addAll(Iterable<MetricReference> references) {
    for (final reference in references) {
      add(reference);
    }
  }

  List<MetricReference> recognize(Object frame, {DateTime? capturedAt}) {
    final references = _recognizer
        .recognize(frame)
        .map((observation) => observation.toReference(capturedAt: capturedAt));
    addAll(references);
    return List.unmodifiable(_references);
  }

  MetricScaleSolution solve() => _solver.solve(_references);

  EvidenceGraph evidenceGraph() {
    var graph = const EvidenceGraph();
    final solution = solve();
    for (final reference in _references) {
      final evidence = solution.evidence.where(
        (item) => item.referenceId == reference.id,
      );
      graph = graph.addMetricReference(
        reference: reference,
        evidence: evidence,
      );
    }
    return graph;
  }
}

FiducialMarker fiducialMarker({
  required String id,
  required double nominalSize,
  String version = '1',
  FiducialMaterial material = FiducialMaterial.paper,
}) => FiducialMarker.create(
  id: id,
  nominalSize: nominalSize,
  version: version,
  material: material,
);
