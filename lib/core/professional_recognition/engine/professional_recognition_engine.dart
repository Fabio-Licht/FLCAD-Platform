import '../../engineering_decision/api/decision_api.dart';
import '../../engineering_decision/models/decision_models.dart' as ede;
import '../../geometric_recognition/engine/geometric_recognition_engine.dart';
import '../../geometric_recognition/models/recognition_models.dart';
import '../../geometric_recognition/plugins/recognition_plugin.dart';
import '../../geometric_recognition/recognizers/supported_recognizers.dart';
import '../advisor/recognition_advisor.dart';
import '../features/feature_composition_engine.dart';
import '../models/professional_recognition_models.dart';
import '../patterns/pattern_recognition_engine.dart';
import '../recognizers/quadric_recognizers.dart';
import '../regions/adaptive_region_growing.dart';
import '../topology/topology_recognition_engine.dart';

class ProfessionalRecognitionEngine {
  ProfessionalRecognitionEngine({
    GeometricRecognitionEngine? urf,
    DecisionApi? decisions,
  }) : decisions = decisions ?? DecisionApi(),
       urf =
           urf ??
           GeometricRecognitionEngine(
             plugins: _plugins(),
             decisions: decisions ?? DecisionApi(),
           );
  final GeometricRecognitionEngine urf;
  final DecisionApi decisions;
  final topology = const TopologyRecognitionEngine();
  final patterns = const PatternRecognitionEngine();
  final features = const FeatureCompositionEngine();
  final regionGrowing = const AdaptiveRegionGrowing();
  final advisor = const RecognitionAdvisor();

  static RecognitionPluginRegistry _plugins() => RecognitionPluginRegistry()
    ..register(const PlaneRecognizer())
    ..register(const SphereRecognizer())
    ..register(const CylinderProfessionalRecognizer())
    ..register(const ConeProfessionalRecognizer())
    ..register(const TorusProfessionalRecognizer());

  Future<ProfessionalRecognitionReport> recognize(
    List<RecognitionContext> regions, {
    Set<PrimitiveType>? allowedTypes,
  }) async {
    final watch = Stopwatch()..start(),
        primitives = <ProfessionalPrimitive>[],
        pending = <String>[];
    for (var pass = 1; pass <= 4; pass++) {
      for (final context in regions) {
        if (pass > 1 &&
            primitives.any(
              (p) =>
                  p.recognition.winner.regionId ==
                      context.observation.regionId &&
                  p.recognition.dna.confidence >= .9,
            )) {
          continue;
        }
        final result = await urf.recognize(
          context,
          allowedTypes: allowedTypes,
          rebuild: pass > 1,
        );
        if (result.winner.type == PrimitiveType.unknown) {
          if (pass == 4) pending.add(context.observation.regionId);
          continue;
        }
        final residuals = _residuals(result, context),
            sorted = [...residuals]..sort(),
            threshold = sorted.isEmpty
                ? 0.0
                : sorted[(sorted.length * .8).floor().clamp(
                    0,
                    sorted.length - 1,
                  )],
            map = ResidualMap(
              residuals,
              [
                for (var i = 0; i < residuals.length; i++)
                  if (residuals[i] <= threshold) i,
              ],
              [
                for (var i = 0; i < residuals.length; i++)
                  if (residuals[i] > threshold) i,
              ],
            );
        primitives.removeWhere(
          (p) => p.recognition.winner.regionId == result.winner.regionId,
        );
        primitives.add(
          ProfessionalPrimitive(
            recognition: result,
            residualMap: map,
            pass: pass,
            auditTrail: [
              'pass=$pass',
              'rms=${result.winner.statistics.rms}',
              'coverage=${result.winner.statistics.coverage}',
              'outliers=${map.outlierIndices.length}',
            ],
          ),
        );
      }
    }
    final relations = topology.analyze(primitives),
        recognizedPatterns = patterns.recognize(primitives),
        recognizedFeatures = features.compose(
          primitives,
          relations,
          recognizedPatterns,
        ),
        functions = _functions(recognizedFeatures),
        manufacturing = _manufacturing(recognizedFeatures);
    watch.stop();
    var report = ProfessionalRecognitionReport(
      projectId: regions.isEmpty
          ? 'unknown'
          : regions.first.observation.projectId,
      primitives: primitives,
      relations: relations,
      features: recognizedFeatures,
      patterns: recognizedPatterns,
      functions: functions,
      manufacturing: manufacturing,
      advice: const [],
      elapsed: watch.elapsed,
      pendingRegionIds: pending,
      createdAt: DateTime.now(),
    );
    report = ProfessionalRecognitionReport(
      projectId: report.projectId,
      primitives: report.primitives,
      relations: report.relations,
      features: report.features,
      patterns: report.patterns,
      functions: report.functions,
      manufacturing: report.manufacturing,
      advice: advisor.advise(report),
      elapsed: report.elapsed,
      pendingRegionIds: report.pendingRegionIds,
      createdAt: report.createdAt,
    );
    await _decide(report);
    return report;
  }

  List<double> _residuals(PrimitiveRecognitionResult r, RecognitionContext c) =>
      List<double>.filled(
        c.observation.points.length,
        r.winner.statistics.mean,
      );
  List<ProbabilisticInference> _functions(List<ProfessionalFeature> values) =>
      values
          .map(
            (f) => ProbabilisticInference(
              f.type == ManufacturingFeatureType.throughHole
                  ? 'fixação'
                  : 'função não determinada',
              f.confidence * .75,
              'Inferência probabilística derivada da composição de feature.',
              [f.id],
            ),
          )
          .toList();
  List<ProbabilisticInference> _manufacturing(
    List<ProfessionalFeature> values,
  ) => values.isEmpty
      ? const []
      : [
          ProbabilisticInference(
            'usinado',
            values.map((e) => e.confidence).reduce((a, b) => a + b) /
                values.length *
                .8,
            'Features regulares sugerem processo de usinagem; material e acabamento não foram observados.',
            values.map((e) => e.id).toList(),
          ),
        ];
  Future<void> _decide(ProfessionalRecognitionReport r) => decisions.create(
    ede.DecisionRequest(
      projectId: r.projectId,
      type: ede.EngineeringDecisionType.workflow,
      origin: ede.DecisionOrigin.cognition,
      title: 'Relatório de reconhecimento profissional',
      impact: 'Orienta reconstrução; não cria CAD.',
      criteria: ede.DecisionCriteria(
        recognitionConfidence: r.averageConfidence,
        meshQuality: r.recognizedCoverage,
        captureCompleteness: r.recognizedCoverage,
        computationalCost: 0,
        reconstructionImpact: r.averageConfidence,
        referenceReuse: 0,
        partComplexity: 0,
        engineeringIntent: r.functions.isEmpty
            ? 0
            : r.functions.first.probability,
        successHistory: 0,
      ),
      evidence: [
        ede.DecisionEvidence(
          id: 'uers-report',
          description:
              '${r.primitives.length} primitivas e ${r.features.length} features',
          source: 'UERS',
          value: r.averageConfidence,
        ),
      ],
    ),
  );
}
