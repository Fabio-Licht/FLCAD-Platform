import 'dart:math' as math;

import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/recognizers/quadric_recognizers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('controlled complete and inclined cylinders recover radius', () {
    for (final points in [
      _cylinder(),
      _cylinder(axis: const Vector3(.3, .4, .8660254038)),
    ]) {
      final candidate = const CylinderProfessionalRecognizer().evaluate(
        _context(points),
      );
      expect(candidate.parameters['radius'], closeTo(5, .05));
      expect(candidate.statistics.rms, lessThan(.1));
      expect(candidate.statistics.maximum, lessThan(.2));
    }
  });

  test(
    'partial cylinder remains measurable but is not given new guarantees',
    () {
      final candidate = const CylinderProfessionalRecognizer().evaluate(
        _context(_cylinder(startAngle: 0, endAngle: math.pi / 2)),
      );
      expect(candidate.parameters['radius'], isA<num>());
      expect(candidate.statistics.rms.isFinite, isTrue);
      // Angular coverage is not represented by FitStatistics.coverage.
      expect(candidate.statistics.coverage, inInclusiveRange(0, 1));
    },
  );

  test('insufficient selections are not detected as cylinders', () {
    final recognizer = const CylinderProfessionalRecognizer();
    expect(
      recognizer.detect(
        _context([for (var z = 0; z < 5; z++) Vector3(z.toDouble(), 0, 0)]),
      ),
      isFalse,
    );
  });
}

RecognitionContext _context(List<Vector3> points) => RecognitionContext(
  observation: RecognitionObservation(
    projectId: 'fixture-project',
    meshId: 'fixture-mesh',
    regionId: 'cylinder-region',
    points: points,
    meshFingerprint: 'fixture-mesh-fingerprint',
    regionFingerprint: 'cylinder-region-fingerprint',
  ),
);

List<Vector3> _cylinder({
  Vector3 axis = const Vector3(0, 0, 1),
  double startAngle = 0,
  double endAngle = 2 * math.pi,
}) {
  final reference = axis.z.abs() < .9
      ? const Vector3(0, 0, 1)
      : const Vector3(1, 0, 0);
  final u = axis.cross(reference).normalized;
  final v = axis.cross(u).normalized;
  return [
    for (var z = -10; z <= 10; z++)
      for (var i = 0; i < 48; i++)
        u * (5 * math.cos(startAngle + (endAngle - startAngle) * i / 47)) +
            v * (5 * math.sin(startAngle + (endAngle - startAngle) * i / 47)) +
            axis * z.toDouble(),
  ];
}
