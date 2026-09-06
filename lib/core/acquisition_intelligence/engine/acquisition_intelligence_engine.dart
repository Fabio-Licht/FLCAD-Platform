import '../models/evidence_graph.dart';
import '../models/universal_capture_contract.dart';
import 'acquisition_analyzers.dart';

class CaptureHealth {
  const CaptureHealth({
    required this.score,
    required this.confidence,
    required this.recommendations,
    required this.evidence,
  });

  final double score;
  final double confidence;
  final List<CaptureRecommendation> recommendations;
  final CaptureEvidence evidence;

  bool get isHealthy => score >= .7;

  Map<String, dynamic> toJson() => {
    'score': score,
    'confidence': confidence,
    'recommendations': recommendations.map((e) => e.name).toList(),
    'evidence': evidence.toJson(),
  };
}

class NextBestView {
  const NextBestView({
    required this.azimuthDegrees,
    required this.elevationDegrees,
    required this.reason,
    required this.confidence,
  });

  final double azimuthDegrees;
  final double elevationDegrees;
  final String reason;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'azimuthDegrees': azimuthDegrees,
    'elevationDegrees': elevationDegrees,
    'reason': reason,
    'confidence': confidence,
  };
}

class NextBestViewPlanner {
  const NextBestViewPlanner();

  NextBestView plan(Iterable<UniversalCaptureContract> captures) {
    final sectors = <int>{};
    for (final capture in captures) {
      final pose = capture.pose;
      if (pose == null) continue;
      final sector = ((pose.azimuthDegrees + 180) ~/ 45) % 8;
      sectors.add(sector);
    }
    final missing = List<int>.generate(
      8,
      (index) => index,
    ).firstWhere((sector) => !sectors.contains(sector), orElse: () => 0);
    final azimuth = missing * 45.0 - 180.0 + 22.5;
    return NextBestView(
      azimuthDegrees: azimuth,
      elevationDegrees: 0,
      reason: sectors.length < 8
          ? CaptureRecommendation.captureMissingArea.name
          : CaptureRecommendation.goodDistance.name,
      confidence: sectors.isEmpty ? 0 : (1 - sectors.length / 8).clamp(.2, .9),
    );
  }
}

class AcquisitionIntelligenceEngine {
  const AcquisitionIntelligenceEngine({
    this.distance = const DistanceAnalyzer(),
    this.blur = const BlurDetector(),
    this.exposure = const ExposureAnalyzer(),
    this.reflection = const ReflectionDetector(),
    this.coverage = const CoverageAnalyzer(),
    this.position = const PositionAnalyzer(),
    this.stability = const StabilityAnalyzer(),
    this.nextBestView = const NextBestViewPlanner(),
  });

  final DistanceAnalyzer distance;
  final BlurDetector blur;
  final ExposureAnalyzer exposure;
  final ReflectionDetector reflection;
  final CoverageAnalyzer coverage;
  final PositionAnalyzer position;
  final StabilityAnalyzer stability;
  final NextBestViewPlanner nextBestView;

  CaptureHealth analyze(UniversalCaptureContract capture) {
    final distanceResult = distance.analyze(capture);
    final blurResult = blur.analyze(capture);
    final exposureResult = exposure.analyze(capture);
    final reflectionResult = reflection.analyze(capture);
    final coverageResult = coverage.analyze(capture);
    final positionResult = position.analyze(capture);
    final values = [
      distanceResult.score,
      blurResult.score,
      exposureResult.score,
      reflectionResult.score,
      coverageResult.score,
      stability.analyze(capture),
    ];
    final score = values.reduce((a, b) => a + b) / values.length;
    final recommendations = <CaptureRecommendation?>[
      distanceResult.recommendation,
      blurResult.recommendation,
      exposureResult.recommendation,
      reflectionResult.recommendation,
      coverageResult.recommendation,
    ].whereType<CaptureRecommendation>().toSet().toList();
    final evidence = CaptureEvidence(
      captureId: capture.id,
      quality: score,
      positionConfidence: positionResult.score,
      exposure: exposureResult.score,
      focus: blurResult.score,
      coverage: coverageResult.score,
      reflection: reflectionResult.score,
      recommendations: recommendations,
      confidence: (positionResult.score + score) / 2,
    );
    return CaptureHealth(
      score: score,
      confidence: evidence.confidence,
      recommendations: recommendations,
      evidence: evidence,
    );
  }

  NextBestView recommendNextView(Iterable<UniversalCaptureContract> captures) =>
      nextBestView.plan(captures);

  EvidenceGraph buildEvidenceGraph(
    Iterable<UniversalCaptureContract> captures,
  ) {
    var graph = const EvidenceGraph();
    for (final capture in captures) {
      final health = analyze(capture);
      graph = graph.addCapture(
        captureId: capture.id,
        capture: capture.toJson(),
        evidence: health.toJson(),
      );
    }
    return graph;
  }
}
