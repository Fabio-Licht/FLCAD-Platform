import 'dart:io';

import 'package:flcad_mobile/core/acquisition_intelligence/acquisition_intelligence.dart';
import 'package:flutter_test/flutter_test.dart';

UniversalCaptureContract capture({
  String id = 'capture-1',
  double distance = .8,
  double blur = .9,
  double exposure = .5,
  double reflection = .1,
  double coverage = .8,
  double stability = .9,
  double poseConfidence = .8,
  double azimuth = 0,
}) => UniversalCaptureContract(
  id: id,
  sessionId: 'session-1',
  source: CaptureSourceKind.camera,
  capturedAt: DateTime.utc(2026, 8, 22),
  imagePath: '/captures/$id.jpg',
  pose: CapturePose(
    azimuthDegrees: azimuth,
    elevationDegrees: 0,
    confidence: poseConfidence,
  ),
  distanceMeters: distance,
  blurScore: blur,
  exposureValue: exposure,
  reflectionScore: reflection,
  coverageScore: coverage,
  stabilityScore: stability,
);

void main() {
  const engine = AcquisitionIntelligenceEngine();

  test('aggregates acquisition health without blocking a capture', () {
    final health = engine.analyze(
      capture(
        distance: .05,
        blur: .2,
        exposure: .1,
        reflection: .8,
        coverage: .2,
      ),
    );

    expect(health.score, lessThan(.7));
    expect(health.recommendations, contains(CaptureRecommendation.moveFurther));
    expect(
      health.recommendations,
      contains(CaptureRecommendation.improveFocus),
    );
    expect(health.evidence.captureId, 'capture-1');
  });

  test('keeps every capture and links it to evidence', () {
    final graph = engine.buildEvidenceGraph([
      capture(id: 'one'),
      capture(id: 'two', azimuth: 90),
    ]);

    expect(graph.nodes, hasLength(4));
    expect(graph.edges, hasLength(2));
    expect(graph.nodes.map((node) => node.id), contains('capture:one'));
    expect(graph.nodes.map((node) => node.id), contains('evidence:two'));
  });

  test('next best view selects an uncovered angular sector', () {
    final recommendation = engine.recommendNextView([
      capture(azimuth: 0),
      capture(id: 'capture-2', azimuth: 45),
    ]);

    expect(
      recommendation.reason,
      CaptureRecommendation.captureMissingArea.name,
    );
    expect(recommendation.confidence, greaterThan(0));
  });

  test('persists and reopens the complete acquisition evidence', () async {
    final directory = await Directory.systemTemp.createTemp('m003-');
    addTearDown(() => directory.delete(recursive: true));
    final captures = [capture(id: 'persistent')];
    final evidence = captures
        .map(engine.analyze)
        .map((health) => health.evidence)
        .toList();
    final graph = engine.buildEvidenceGraph(captures);
    final repository = AcquisitionEvidenceRepository(directory: directory);

    await repository.save(
      AcquisitionEvidenceSnapshot(
        projectId: 'project/one',
        captures: captures,
        evidence: evidence,
        graph: graph,
      ),
    );
    final reopened = await repository.load('project/one');

    expect(reopened, isNotNull);
    expect(reopened!.projectId, 'project/one');
    expect(reopened.captures.single.id, 'persistent');
    expect(reopened.captures.single.capturedAt, captures.single.capturedAt);
    expect(reopened.captures.single.metadata, captures.single.metadata);
    expect(reopened.evidence.single.quality, evidence.single.quality);
    expect(reopened.evidence.single.confidence, evidence.single.confidence);
    expect(reopened.evidence.single.coverage, evidence.single.coverage);
    expect(reopened.graph.nodes, hasLength(2));
    expect(reopened.graph.edges, hasLength(1));
  });
}
