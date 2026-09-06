import '../models/universal_capture_contract.dart';

class DistanceAnalysis {
  const DistanceAnalysis({required this.score, required this.recommendation});
  final double score;
  final CaptureRecommendation? recommendation;
}

class DistanceAnalyzer {
  const DistanceAnalyzer({this.minimumMeters = .15, this.maximumMeters = 2.5});

  final double minimumMeters;
  final double maximumMeters;

  DistanceAnalysis analyze(UniversalCaptureContract capture) {
    final distance = capture.distanceMeters;
    if (distance == null || !distance.isFinite || distance <= 0) {
      return const DistanceAnalysis(score: 0, recommendation: null);
    }
    if (distance < minimumMeters) {
      return const DistanceAnalysis(
        score: 0.35,
        recommendation: CaptureRecommendation.moveFurther,
      );
    }
    if (distance > maximumMeters) {
      return const DistanceAnalysis(
        score: 0.35,
        recommendation: CaptureRecommendation.moveCloser,
      );
    }
    final center = (minimumMeters + maximumMeters) / 2;
    final halfRange = (maximumMeters - minimumMeters) / 2;
    final score = (1 - ((distance - center).abs() / halfRange) * .35)
        .clamp(0.0, 1.0)
        .toDouble();
    return DistanceAnalysis(score: score, recommendation: null);
  }
}

class BlurAnalysis {
  const BlurAnalysis({required this.score, required this.recommendation});
  final double score;
  final CaptureRecommendation? recommendation;
}

class BlurDetector {
  const BlurDetector();

  BlurAnalysis analyze(UniversalCaptureContract capture) {
    final score = capture.blurScore?.clamp(0.0, 1.0).toDouble() ?? 0;
    return BlurAnalysis(
      score: score,
      recommendation: score < .6 ? CaptureRecommendation.improveFocus : null,
    );
  }
}

class ExposureAnalysis {
  const ExposureAnalysis({required this.score, required this.recommendation});
  final double score;
  final CaptureRecommendation? recommendation;
}

class ExposureAnalyzer {
  const ExposureAnalyzer();

  ExposureAnalysis analyze(UniversalCaptureContract capture) {
    final value = capture.exposureValue;
    if (value == null || !value.isFinite) {
      return const ExposureAnalysis(score: 0, recommendation: null);
    }
    final score = (1 - (value - .5).abs() * 2).clamp(0.0, 1.0).toDouble();
    return ExposureAnalysis(
      score: score,
      recommendation: value < .25
          ? CaptureRecommendation.increaseLight
          : value > .8
          ? CaptureRecommendation.decreaseLight
          : null,
    );
  }
}

class ReflectionAnalysis {
  const ReflectionAnalysis({required this.score, required this.recommendation});
  final double score;
  final CaptureRecommendation? recommendation;
}

class ReflectionDetector {
  const ReflectionDetector();

  ReflectionAnalysis analyze(UniversalCaptureContract capture) {
    final glare = capture.reflectionScore?.clamp(0.0, 1.0).toDouble() ?? 0;
    return ReflectionAnalysis(
      score: 1 - glare,
      recommendation: glare > .4
          ? CaptureRecommendation.reduceReflection
          : null,
    );
  }
}

class CoverageAnalysis {
  const CoverageAnalysis({required this.score, required this.recommendation});
  final double score;
  final CaptureRecommendation? recommendation;
}

class CoverageAnalyzer {
  const CoverageAnalyzer();

  CoverageAnalysis analyze(UniversalCaptureContract capture) {
    final score = capture.coverageScore?.clamp(0.0, 1.0).toDouble() ?? 0;
    return CoverageAnalysis(
      score: score,
      recommendation: score < .6
          ? CaptureRecommendation.captureMissingArea
          : null,
    );
  }
}

class PositionAnalysis {
  const PositionAnalysis({required this.score});
  final double score;
}

class PositionAnalyzer {
  const PositionAnalyzer();

  PositionAnalysis analyze(UniversalCaptureContract capture) {
    final pose = capture.pose;
    if (pose == null) return const PositionAnalysis(score: 0);
    return PositionAnalysis(score: pose.confidence.clamp(0.0, 1.0).toDouble());
  }
}

class StabilityAnalyzer {
  const StabilityAnalyzer();

  double analyze(UniversalCaptureContract capture) =>
      capture.stabilityScore?.clamp(0.0, 1.0).toDouble() ?? 0;
}
