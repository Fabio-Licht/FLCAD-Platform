import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/core/sketch_editor/health/sketch_health_analyzer.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';

void main() {
  const analyzer = SketchHealthAnalyzer();

  test('accepts a closed mixed line and arc profile', () {
    final report = analyzer.analyze([
      SketchLine(
        const SketchVector(0, 0),
        const SketchVector(10, 0),
        id: 'bottom',
      ),
      SketchLine(
        const SketchVector(10, 0),
        const SketchVector(10, 5),
        id: 'right',
      ),
      SketchArc(const SketchVector(5, 5), 5, 0, math.pi, id: 'arc'),
      SketchLine(
        const SketchVector(0, 5),
        const SketchVector(0, 0),
        id: 'left',
      ),
    ]);

    expect(report.closedProfile, isTrue);
    expect(report.issues, isEmpty);
    expect(report.readyForSurface, isTrue);
  });

  test('reports a measurable, safely repairable gap', () {
    final report = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0), id: 'a'),
      SketchLine(
        const SketchVector(10.018, 0),
        const SketchVector(10, 10),
        id: 'b',
      ),
    ]);
    final gap = report.ofType(SketchHealthIssueType.gap).single;

    expect(gap.distance, closeTo(.018, 1e-9));
    expect(gap.entityIds, containsAll(['a', 'b']));
    expect(gap.endpointReferences, hasLength(2));
    expect(gap.canAutoHeal, isTrue);
    expect(report.readyForSurface, isFalse);
  });

  test('detects reversed duplicates, overlap and coincident circles', () {
    final duplicates = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0), id: 'a'),
      SketchLine(const SketchVector(10, 0), const SketchVector(0, 0), id: 'b'),
    ]);
    final overlap = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0), id: 'a'),
      SketchLine(const SketchVector(3, 0), const SketchVector(12, 0), id: 'c'),
    ]);
    final circles = analyzer.analyze([
      SketchCircle(const SketchVector(20, 20), 4, id: 'c1'),
      SketchCircle(const SketchVector(20, 20), 4, id: 'c2'),
    ]);

    expect(duplicates.ofType(SketchHealthIssueType.duplicate), hasLength(1));
    expect(overlap.ofType(SketchHealthIssueType.overlap), isNotEmpty);
    expect(circles.ofType(SketchHealthIssueType.duplicate), hasLength(1));
  });

  test('detects an interior crossing and tiny geometry', () {
    final report = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 10), id: 'a'),
      SketchLine(const SketchVector(0, 10), const SketchVector(10, 0), id: 'b'),
      SketchLine(
        const SketchVector(20, 20),
        const SketchVector(20.001, 20),
        id: 'tiny',
      ),
    ]);

    expect(report.hasSelfIntersections, isTrue);
    expect(report.hasTinyGeometry, isTrue);
    expect(report.hasOpenEnds, isTrue);
  });

  test('analysis never mutates authoritative geometry', () {
    final line = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'line',
    );
    final before = line.toJson().toString();
    analyzer.analyze([line]);
    expect(line.toJson().toString(), before);
  });

  test('closed section spline is a valid profile', () {
    final spline = SketchSpline(const [
      SketchVector(0, 0),
      SketchVector(2, 0),
      SketchVector(2, 2),
      SketchVector(0, 2),
      SketchVector(0, 0),
    ]);
    final report = analyzer.analyze([spline]);
    expect(report.closedProfile, isTrue);
    expect(report.readyForSurface, isTrue);
  });

  test('separate closed profiles are warnings, not surface blockers', () {
    final report = analyzer.analyze([
      SketchCircle(const SketchVector(0, 0), 1, id: 'main-circle'),
      SketchCircle(const SketchVector(5, 0), .5, id: 'extra-circle'),
    ]);
    expect(report.hasDisconnected, isTrue);
    expect(report.hasDisconnectedWarnings, isTrue);
    expect(report.warningIssues, hasLength(1));
    expect(report.closedProfile, isTrue);
    expect(report.readyForSurface, isTrue);
    expect(report.activeProfileEntityIds, {'main-circle'});
    expect(report.diagnosticEntityIds, {'extra-circle'});
  });

  test('a spline crossing itself blocks surface preview', () {
    final report = analyzer.analyze([
      SketchSpline(const [
        SketchVector(0, 0),
        SketchVector(2, 2),
        SketchVector(0, 2),
        SketchVector(2, 0),
        SketchVector(0, 0),
      ]),
    ]);
    expect(report.hasSelfIntersections, isTrue);
    expect(report.readyForSurface, isFalse);
  });

  test(
    'closed active loop allows loose section leftovers as compact warning',
    () {
      final report = analyzer.analyze([
        SketchLine(
          const SketchVector(0, 0),
          const SketchVector(10, 0),
          id: 'bottom',
        ),
        SketchLine(
          const SketchVector(10, 0),
          const SketchVector(10, 10),
          id: 'right',
        ),
        SketchLine(
          const SketchVector(10, 10),
          const SketchVector(0, 10),
          id: 'top',
        ),
        SketchLine(
          const SketchVector(0, 10),
          const SketchVector(0, 0),
          id: 'left',
        ),
        for (var index = 0; index < 18; index++)
          SketchLine(
            SketchVector(30.0 + index, 0),
            SketchVector(30.2 + index, .3),
            id: 'loose-$index',
          ),
      ]);

      expect(report.closedProfile, isTrue);
      expect(report.readyForSurface, isTrue);
      expect(report.hasOpenEnds, isFalse);
      expect(report.hasGaps, isFalse);
      expect(report.activeProfileEntityIds, {'bottom', 'right', 'top', 'left'});
      final warning = report.ofType(SketchHealthIssueType.disconnected).single;
      expect(warning.blocking, isFalse);
      expect(warning.entityIds, hasLength(18));
      expect(warning.message, '18 loose entities outside active profile');
      expect(warning.message, isNot(contains('loose-0')));
    },
  );

  test('gap in the active open profile remains a blocking error', () {
    final report = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(10, 0), id: 'a'),
      SketchLine(
        const SketchVector(10.05, 0),
        const SketchVector(10, 10),
        id: 'b',
      ),
      SketchLine(
        const SketchVector(10, 10),
        const SketchVector(0, 10),
        id: 'c',
      ),
      SketchLine(const SketchVector(0, 10), const SketchVector(0, 0), id: 'd'),
    ]);

    final gap = report.ofType(SketchHealthIssueType.gap).single;
    expect(report.closedProfile, isFalse);
    expect(report.readyForSurface, isFalse);
    expect(report.hasGaps, isTrue);
    expect(gap.blocking, isTrue);
    expect(gap.canAutoHeal, isTrue);
  });

  test('a simple open chain is never classified as a closed profile', () {
    final report = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(5, 0), id: 'a'),
      SketchLine(const SketchVector(5, 0), const SketchVector(10, 0), id: 'b'),
    ]);

    expect(report.closedProfile, isFalse);
    expect(report.readyForSurface, isFalse);
    expect(report.hasOpenEnds, isTrue);
    expect(report.activeProfileEntityIds, {'a', 'b'});
  });

  test('nearby but unconnected endpoints report a blocking active gap', () {
    final report = analyzer.analyze([
      SketchLine(const SketchVector(0, 0), const SketchVector(5, 0), id: 'a'),
      SketchLine(
        const SketchVector(5.025, 0),
        const SketchVector(10, 0),
        id: 'b',
      ),
    ]);

    expect(report.closedProfile, isFalse);
    expect(report.readyForSurface, isFalse);
    expect(report.blockingOfType(SketchHealthIssueType.gap), hasLength(1));
  });

  test('an explicit open selection is not replaced by another closed loop', () {
    final report = analyzer.analyze(
      [
        SketchCircle(const SketchVector(0, 0), 2, id: 'closed-loop'),
        SketchLine(
          const SketchVector(10, 0),
          const SketchVector(15, 0),
          id: 'open-a',
        ),
        SketchLine(
          const SketchVector(15, 0),
          const SketchVector(20, 0),
          id: 'open-b',
        ),
      ],
      activeSelection: const ['open-a'],
    );

    expect(report.closedProfile, isFalse);
    expect(report.readyForSurface, isFalse);
    expect(report.activeProfileEntityIds, {'open-a', 'open-b'});
    expect(report.hasOpenEnds, isTrue);
  });

  test(
    'construction and reference entities are ignored by active profile health',
    () {
      final reference = ReferenceGeometry({'kind': 'section'}, id: 'reference');
      final construction = ConstructionGeometry({'kind': 'axis'}, id: 'axis');
      final report = analyzer.analyze([
        SketchCircle(const SketchVector(0, 0), 1, id: 'circle'),
        reference,
        construction,
      ]);

      expect(report.readyForSurface, isTrue);
      expect(report.hasDisconnected, isFalse);
      expect(report.activeProfileEntityIds, {'circle'});
      expect(report.diagnosticEntityIds, isEmpty);
    },
  );

  test(
    'a stale closed loop does not mask the larger open profile without selection',
    () {
      // Old, small, closed leftover loop near the origin. It shares NO vertex
      // with the open profile below, so they are independent components.
      final report = analyzer.analyze([
        SketchLine(
          const SketchVector(0, 0),
          const SketchVector(1, 0),
          id: 'old-a',
        ),
        SketchLine(
          const SketchVector(1, 0),
          const SketchVector(1, 1),
          id: 'old-b',
        ),
        SketchLine(
          const SketchVector(1, 1),
          const SketchVector(0, 1),
          id: 'old-c',
        ),
        SketchLine(
          const SketchVector(0, 1),
          const SketchVector(0, 0),
          id: 'old-d',
        ),
        // Larger profile the operator is drawing, visibly OPEN: the closing
        // segment (10,10)->(10,0) is missing. No endpoints are shared with the
        // stale loop, so endpoint coincidence cannot merge the components.
        SketchLine(
          const SketchVector(20, 0),
          const SketchVector(30, 0),
          id: 'new-a',
        ),
        SketchLine(
          const SketchVector(30, 0),
          const SketchVector(30, 10),
          id: 'new-b',
        ),
        SketchLine(
          const SketchVector(30, 10),
          const SketchVector(20, 10),
          id: 'new-c',
        ),
      ]);

      expect(report.closedProfile, isFalse);
      expect(report.readyForSurface, isFalse);
      expect(report.hasOpenEnds, isTrue);
      // The larger open profile is the active component, not the stale loop.
      expect(report.activeProfileEntityIds, {'new-a', 'new-b', 'new-c'});
      expect(
        report.activeProfileEntityIds,
        isNot(containsAll(<String>['old-a', 'old-b', 'old-c', 'old-d'])),
      );
    },
  );

  test('an explicit selection still wins over a larger closed loop', () {
    final report = analyzer.analyze(
      [
        SketchCircle(const SketchVector(0, 0), 1, id: 'big-closed'),
        SketchLine(
          const SketchVector(20, 0),
          const SketchVector(25, 0),
          id: 'sel-a',
        ),
        SketchLine(
          const SketchVector(25, 0),
          const SketchVector(30, 0),
          id: 'sel-b',
        ),
      ],
      activeSelection: const ['sel-a'],
    );

    expect(report.closedProfile, isFalse);
    expect(report.activeProfileEntityIds, {'sel-a', 'sel-b'});
    expect(report.hasOpenEnds, isTrue);
  });
}
