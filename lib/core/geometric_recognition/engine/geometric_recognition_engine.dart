import '../../engineering_decision/api/decision_api.dart';
import '../../engineering_decision/models/decision_models.dart' as decision;
import '../cache/recognition_cache.dart';
import '../candidates/candidate_generator.dart';
import '../competition/recognition_competition.dart';
import '../confidence/confidence_fusion.dart';
import '../graph/recognition_graph.dart';
import '../models/recognition_models.dart';
import '../plugins/recognition_plugin.dart';
import '../recognizers/supported_recognizers.dart';
import '../repository/recognition_repository.dart';
import '../runtime/recognition_runtime.dart';

class GeometricRecognitionEngine {
  GeometricRecognitionEngine({
    RecognitionPluginRegistry? plugins,
    RecognitionRepository? repository,
    RecognitionCache? cache,
    RecognitionGraph? graph,
    DecisionApi? decisions,
  }) : plugins = plugins ?? RecognitionPluginRegistry(),
       repository = repository ?? InMemoryRecognitionRepository(),
       cache = cache ?? RecognitionCache(),
       graph = graph ?? RecognitionGraph(),
       decisions = decisions ?? DecisionApi() {
    if (this.plugins.recognizers.isEmpty) {
      this.plugins
        ..register(const PlaneRecognizer())
        ..register(const SphereRecognizer());
      for (final type in PrimitiveType.values.where(
        (value) =>
            value != PrimitiveType.plane &&
            value != PrimitiveType.sphere &&
            value != PrimitiveType.unknown,
      )) {
        this.plugins.register(UnsupportedPrimitiveRecognizer(type));
      }
    }
  }
  final RecognitionPluginRegistry plugins;
  final RecognitionRepository repository;
  final RecognitionCache cache;
  final RecognitionGraph graph;
  final DecisionApi decisions;
  final runtime = const RecognitionRuntime();
  final candidateGenerator = const CandidateGenerator();
  final competition = const RecognitionCompetition();
  final confidenceFusion = const RecognitionConfidenceFusion();

  Future<PrimitiveRecognitionResult> recognize(
    RecognitionContext context, {
    Set<PrimitiveType>? allowedTypes,
    void Function(double progress)? onProgress,
    bool rebuild = false,
  }) async {
    final requestKey = _requestKey(allowedTypes);
    if (!rebuild) {
      final cached = cache.read(context, requestKey: requestKey);
      if (cached != null) return cached;
    }
    onProgress?.call(.05);
    final seed = candidateGenerator.generate(context);
    final recognizers = plugins.recognizers
        .where(
          (recognizer) =>
              (allowedTypes == null ||
                  allowedTypes.contains(recognizer.type)) &&
              seed.suggestedTypes.contains(recognizer.type) &&
              recognizer.detect(context),
        )
        .toList();
    final candidates = await Future.wait(
      recognizers.asMap().entries.map(
        (entry) => runtime.run(
          'recognizer:${entry.value.id}:${context.observation.regionId}',
          () {
            try {
              final evaluated = entry.value.evaluate(context),
                  refined = entry.value.refine(context, evaluated);
              return entry.value.validate(context, refined)
                  ? refined.copyWith(status: RecognitionStatus.validated)
                  : refined.copyWith(status: RecognitionStatus.rejected);
            } catch (error) {
              return RecognitionCandidate(
                id: '${entry.value.id}:failed',
                type: entry.value.type,
                regionId: context.observation.regionId,
                parameters: const {},
                statistics: const FitStatistics(
                  rms: double.infinity,
                  maximum: double.infinity,
                  mean: double.infinity,
                  coverage: 0,
                  stability: 0,
                  score: 0,
                ),
                evidence: [
                  RecognitionEvidence(
                    'fit-failed',
                    'Ajuste não convergiu: ${error.runtimeType}',
                    entry.value.id,
                    0,
                  ),
                ],
                origin: entry.value.id,
                status: RecognitionStatus.rejected,
              );
            }
          },
          onProgress: (value) => onProgress?.call(
            .1 + ((entry.key + value) / recognizers.length) * .6,
          ),
        ),
      ),
    );
    final valid = candidates
        .where((candidate) => candidate.status == RecognitionStatus.validated)
        .toList();
    final resolved = valid.isEmpty
        ? _unknown(context)
        : competition.resolve(valid);
    final winner = resolved.winner,
        confidence = valid.isEmpty
            ? 0.0
            : confidenceFusion.fuse(context, winner),
        recognizer = plugins.recognizers
            .where((item) => item.type == winner.type)
            .firstOrNull,
        explanation =
            recognizer?.explain(context, winner, resolved.alternatives) ??
            RecognitionExplanation(
              why: 'Nenhum reconhecedor suportado produziu ajuste válido.',
              evidence: winner.evidence,
              regions: [winner.regionId],
              parameters: winner.parameters,
              losingCandidates: candidates.map((e) => e.type.name).toList(),
              score: 0,
              confidence: 0,
            ),
        dna = RecognitionDNA(
          type: winner.type,
          parameters: winner.parameters,
          regionId: winner.regionId,
          geometricSignature: _signature(context, winner),
          quality: winner.statistics.score,
          confidence: confidence,
          evidence: winner.evidence,
          origin: winner.origin,
          version: '3.0.0',
        ),
        now = DateTime.now(),
        result = PrimitiveRecognitionResult(
          id: 'recognition:${context.observation.regionFingerprint}:${winner.type.name}',
          projectId: context.observation.projectId,
          meshId: context.observation.meshId,
          winner: winner,
          alternatives: resolved.alternatives,
          dna: dna,
          explanation: RecognitionExplanation(
            why: explanation.why,
            evidence: explanation.evidence,
            regions: explanation.regions,
            parameters: explanation.parameters,
            losingCandidates: explanation.losingCandidates,
            score: explanation.score,
            confidence: confidence,
          ),
          createdAt: now,
        );
    cache.write(context, result, requestKey: requestKey);
    graph.add(result);
    await repository.save(result);
    if (winner.type != PrimitiveType.unknown) {
      await _registerDecision(context, result);
    }
    onProgress?.call(1);
    return result;
  }

  Future<void> _registerDecision(
    RecognitionContext context,
    PrimitiveRecognitionResult result,
  ) async {
    await decisions.create(
      decision.DecisionRequest(
        projectId: result.projectId,
        type: decision.EngineeringDecisionType.workflow,
        origin: decision.DecisionOrigin.cognition,
        title: 'Reconhecimento ${result.winner.type.name}',
        criteria: decision.DecisionCriteria(
          recognitionConfidence: result.dna.confidence,
          meshQuality: result.winner.statistics.stability,
          captureCompleteness: result.winner.statistics.coverage,
          computationalCost: 0,
          reconstructionImpact: result.dna.confidence,
          referenceReuse: 0,
          partComplexity: 0,
          engineeringIntent: context.cognitionConfidence,
          successHistory: context.historicalSuccess,
        ),
        evidence: result.dna.evidence
            .map(
              (e) => decision.DecisionEvidence(
                id: e.id,
                description: e.description,
                source: e.source,
                value: e.value,
              ),
            )
            .toList(),
        impact: 'Disponibiliza hipótese geométrica; não cria CAD.',
        regionId: result.winner.regionId,
      ),
    );
  }

  RecognitionCompetitionResult _unknown(RecognitionContext context) {
    final candidate = RecognitionCandidate(
      id: 'unknown:${context.observation.regionFingerprint}',
      type: PrimitiveType.unknown,
      regionId: context.observation.regionId,
      parameters: const {},
      statistics: const FitStatistics(
        rms: 0,
        maximum: 0,
        mean: 0,
        coverage: 0,
        stability: 0,
        score: 0,
      ),
      evidence: const [],
      origin: 'urf',
      status: RecognitionStatus.indeterminate,
    );
    return RecognitionCompetitionResult(candidate, const [], const []);
  }

  String _signature(
    RecognitionContext context,
    RecognitionCandidate candidate,
  ) =>
      '${context.observation.meshFingerprint}:${context.observation.regionFingerprint}:'
      '${candidate.type.name}:${candidate.parameters}';

  String _requestKey(Set<PrimitiveType>? allowedTypes) {
    if (allowedTypes == null) return 'automatic';
    if (allowedTypes.isEmpty) return 'none';
    final names = allowedTypes.map((type) => type.name).toList()..sort();
    return 'types:${names.join(',')}';
  }
}
