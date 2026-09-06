import 'dart:io';

import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/metric_reference/metric_reference.dart';
import 'package:flutter_test/flutter_test.dart';

MetricReference reference({
  String id = 'distance-1',
  double knownValue = 20,
  LengthUnit unit = LengthUnit.millimeter,
}) => MetricReference(
  id: id,
  type: MetricReferenceType.distance,
  pointA: Vector3.zero,
  pointB: const Vector3(10, 0, 0),
  knownValue: knownValue,
  unit: unit,
  createdAt: DateTime.utc(2026, 8, 22),
  metadata: const {'source': 'operator'},
);

void main() {
  const solver = MetricReferenceSolver();

  test('solves a known distance with explicit units', () {
    final solution = solver.solve([reference()]);

    expect(solution.isSolvable, isTrue);
    expect(solution.scaleFactor, 2);
    expect(solution.evidence.single.referenceId, 'distance-1');
    expect(solution.hasConflicts, isFalse);
  });

  test('supports length, width and diameter references without mutation', () {
    final refs = [
      reference(id: 'length', knownValue: 20),
      reference(id: 'width', knownValue: 2, unit: LengthUnit.centimeter),
      MetricReference(
        id: 'diameter',
        type: MetricReferenceType.diameter,
        pointA: Vector3.zero,
        pointB: const Vector3(5, 0, 0),
        knownValue: 10,
        unit: LengthUnit.millimeter,
        createdAt: DateTime.utc(2026, 8, 22),
      ),
    ];
    final solution = solver.solve(refs);

    expect(solution.scaleFactor, 2);
    expect(solution.references.map((item) => item.id), [
      'length',
      'width',
      'diameter',
    ]);
    expect(solution.references, isNot(same(refs)));
    expect(
      solution.evidence,
      everyElement(
        predicate<MetricReferenceEvidence>((item) => !item.conflict),
      ),
    );
  });

  test(
    'retains conflicting evidence instead of silently changing geometry',
    () {
      final solution = solver.solve([
        reference(id: 'consistent', knownValue: 20),
        reference(id: 'conflicting', knownValue: 40),
      ]);

      expect(solution.hasConflicts, isTrue);
      expect(solution.references, hasLength(2));
      expect(
        solution.evidence.map((item) => item.referenceId),
        contains('conflicting'),
      );
    },
  );

  test('persists and reopens references, solution and evidence', () async {
    final directory = await Directory.systemTemp.createTemp('m004-');
    addTearDown(() => directory.delete(recursive: true));
    final refs = [reference()];
    final solution = solver.solve(refs);
    final repository = MetricReferenceRepository(directory: directory);

    await repository.save(
      MetricReferenceSnapshot(
        projectId: 'project/metric',
        references: refs,
        solution: solution,
      ),
    );
    final reopened = await repository.load('project/metric');

    expect(reopened, isNotNull);
    expect(reopened!.projectId, 'project/metric');
    expect(reopened.references.single.id, 'distance-1');
    expect(reopened.references.single.knownMillimeters, 20);
    expect(reopened.solution.scaleFactor, 2);
    expect(reopened.solution.evidence.single.confidence, 1);
  });
}
