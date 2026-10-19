import 'dart:io';

import 'dart:math' as math;

import 'package:flcad_mobile/core/fel/commands/native_commands.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/engine/professional_recognition_engine.dart';
import 'package:flcad_mobile/core/professional_recognition/features/feature_composition_engine.dart';
import 'package:flcad_mobile/core/professional_recognition/learning/recognition_learning.dart';
import 'package:flcad_mobile/core/professional_recognition/models/professional_recognition_models.dart';
import 'package:flcad_mobile/core/professional_recognition/patterns/pattern_recognition_engine.dart';
import 'package:flcad_mobile/core/professional_recognition/recognizers/quadric_recognizers.dart';
import 'package:flcad_mobile/core/professional_recognition/regions/adaptive_region_growing.dart';
import 'package:flcad_mobile/core/professional_recognition/topology/topology_recognition_engine.dart';
import 'package:flutter_test/flutter_test.dart';

RecognitionContext contextFor(String id, List<Vector3> points) =>
    RecognitionContext(
      observation: RecognitionObservation(
        projectId: 'p',
        meshId: 'm',
        regionId: id,
        points: points,
        meshFingerprint: 'mesh',
        regionFingerprint: id,
      ),
      areiConfidence: .8,
      knowledgeConfidence: .8,
      cognitionConfidence: .8,
      decisionConfidence: .8,
      historicalSuccess: .8,
    );
List<Vector3> cylinder({double x = 0}) => [
  for (final z in [-2.0, -1.0, 0.0, 1.0, 2.0])
    for (var i = 0; i < 12; i++)
      Vector3(x + math.cos(i * math.pi / 6), math.sin(i * math.pi / 6), z),
];
List<Vector3> cone() => [
  for (final z in [-2.0, -1.0, 0.0, 1.0, 2.0])
    for (var i = 0; i < 12; i++)
      Vector3(
        (2.5 + .3 * z) * math.cos(i * math.pi / 6),
        (2.5 + .3 * z) * math.sin(i * math.pi / 6),
        z,
      ),
];
List<Vector3> torus() => [
  for (var a = 0; a < 12; a++)
    for (var b = 0; b < 8; b++)
      Vector3(
        (3 + math.cos(b * math.pi / 4)) * math.cos(a * math.pi / 6),
        (3 + math.cos(b * math.pi / 4)) * math.sin(a * math.pi / 6),
        math.sin(b * math.pi / 4),
      ),
];

void main() {
  test('professional cylinder cone and torus produce auditable fits', () {
    final c = const CylinderProfessionalRecognizer().evaluate(
          contextFor('c', cylinder()),
        ),
        k = const ConeProfessionalRecognizer().evaluate(
          contextFor('k', cone()),
        ),
        t = const TorusProfessionalRecognizer().evaluate(
          contextFor('t', torus()),
        );
    expect(c.parameters['radius'], closeTo(1, .05));
    expect(k.parameters['halfAngle'], greaterThan(0));
    expect(t.parameters['majorRadius'], closeTo(3, .2));
    for (final value in [c, k, t]) {
      expect(value.statistics.rms.isFinite, isTrue);
      expect(value.evidence, isNotEmpty);
    }
  });

  test(
    'multi-pass engine creates residual map, features, inference, analytics and EDE report',
    () async {
      final report = await ProfessionalRecognitionEngine().recognize([
        contextFor('cylinder', cylinder()),
      ]);
      expect(report.primitives, hasLength(1));
      expect(report.primitives.single.pass, inInclusiveRange(1, 4));
      expect(report.primitives.single.auditTrail, hasLength(4));
      expect(report.features, isNotEmpty);
      expect(report.functions.single.probability, lessThan(1));
      expect(report.manufacturing.single.probability, lessThan(1));
      expect(report.statisticsByType, isNotEmpty);
      expect(report.averageConfidence, inInclusiveRange(0, 1));
    },
  );

  test('professional engine honors allowedTypes', () async {
    final report = await ProfessionalRecognitionEngine().recognize(
      [
        contextFor('directed-sphere', [
          Vector3(1, 0, 0),
          Vector3(-1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(0, -1, 0),
          Vector3(0, 0, 1),
          Vector3(0, 0, -1),
          Vector3(.707106, .707106, 0),
        ]),
      ],
      allowedTypes: {PrimitiveType.plane},
    );
    expect(
      report.primitives.single.recognition.winner.type,
      PrimitiveType.plane,
    );
  });

  test(
    'topology detects coaxial primitives and composition proposes counterbore',
    () async {
      final engine = ProfessionalRecognitionEngine(),
          report = await engine.recognize([
            contextFor('a', cylinder()),
            contextFor('b', cylinder()),
          ]);
      final relations = const TopologyRecognitionEngine().analyze(
        report.primitives,
      );
      expect(
        relations.any((r) => r.type == TopologicalRelationType.coaxial),
        isTrue,
      );
      final features = const FeatureCompositionEngine().compose(
        report.primitives,
        relations,
        const [],
      );
      expect(
        features.any((f) => f.type == ManufacturingFeatureType.counterbore),
        isTrue,
      );
    },
  );

  test('pattern engine recognizes three aligned cylinders', () async {
    final report = await ProfessionalRecognitionEngine().recognize([
      contextFor('a', cylinder(x: 0)),
      contextFor('b', cylinder(x: 4)),
      contextFor('c', cylinder(x: 8)),
    ]);
    final patterns = const PatternRecognitionEngine().recognize(
      report.primitives,
    );
    expect(patterns.single.kind, 'linear');
    expect(patterns.single.confidence, greaterThan(.8));
  });

  test('adaptive region growing proposes split from curvature and normals', () {
    final base = contextFor('r', cylinder()),
        observation = RecognitionObservation(
          projectId: 'p',
          meshId: 'm',
          regionId: 'r',
          points: base.observation.points,
          normals: const [Vector3(1, 0, 0), Vector3(0, 1, 0)],
          curvatures: const [1, 1],
          meshFingerprint: 'm',
          regionFingerprint: 'r',
        );
    expect(
      const AdaptiveRegionGrowing()
          .evaluate([RecognitionContext(observation: observation)])
          .single
          .action,
      'split',
    );
  });

  test('learning stores feedback-derived thresholds', () async {
    final learning = RecognitionLearning();
    await learning.record(
      projectId: 'p',
      recognitionId: 'r',
      feedback: RecognitionFeedback.corrected,
      confidence: .6,
      correction: 'cylinder',
    );
    expect(learning.learnedThreshold(RecognitionFeedback.corrected), .6);
  });

  test('FEL registers professional recognition vocabulary', () {
    final names = createNativeCommandRegistry(Directory.systemTemp).names;
    for (final name in [
      'RECOGNIZE FEATURES',
      'RECOGNIZE PRIMITIVES',
      'RECOGNIZE PATTERNS',
      'RECOGNIZE TOPOLOGY',
      'SHOW FEATURE GRAPH',
      'SHOW PRIMITIVE GRAPH',
      'SHOW MANUFACTURING',
      'SHOW FUNCTION',
      'SHOW RECOGNITION REPORT',
      'EXPORT RECOGNITION',
    ]) {
      expect(names, contains(name));
    }
  });
}
