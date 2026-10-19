import 'dart:io';
import 'dart:isolate';

import 'package:flcad_mobile/core/engineering_decision/api/decision_api.dart';
import 'package:flcad_mobile/core/engineering_decision/engine/engineering_decision_engine.dart';
import 'package:flcad_mobile/core/fel/commands/native_commands.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_recognition/cache/recognition_cache.dart';
import 'package:flcad_mobile/core/geometric_recognition/candidates/candidate_generator.dart';
import 'package:flcad_mobile/core/geometric_recognition/competition/recognition_competition.dart';
import 'package:flcad_mobile/core/geometric_recognition/confidence/confidence_fusion.dart';
import 'package:flcad_mobile/core/geometric_recognition/engine/geometric_recognition_engine.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/geometric_recognition/pipeline/recognition_pipeline.dart';
import 'package:flcad_mobile/core/geometric_recognition/plugins/recognition_plugin.dart';
import 'package:flcad_mobile/core/geometric_recognition/recognizers/supported_recognizers.dart';
import 'package:flcad_mobile/core/geometric_recognition/recognizers/universal_recognizer.dart';
import 'package:flcad_mobile/core/geometric_recognition/runtime/recognition_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

RecognitionContext planeContext({String fingerprint = 'r1'}) =>
    RecognitionContext(
      observation: RecognitionObservation(
        projectId: 'p',
        meshId: 'm',
        regionId: 'r',
        points: const [
          Vector3(0, 0, 2),
          Vector3(1, 0, 2),
          Vector3(0, 1, 2),
          Vector3(1, 1, 2),
          Vector3(.5, .3, 2),
        ],
        normals: const [Vector3(0, 0, 1), Vector3(0, 0, 1)],
        meshFingerprint: 'mesh',
        regionFingerprint: fingerprint,
      ),
      areiConfidence: .8,
      knowledgeConfidence: .7,
      cognitionConfidence: .85,
      decisionConfidence: .75,
      historicalSuccess: .8,
    );

void main() {
  test('candidate generator derives descriptors without fixed dimensions', () {
    final seed = const CandidateGenerator().generate(planeContext());
    expect(
      seed.suggestedTypes,
      containsAll([PrimitiveType.plane, PrimitiveType.sphere]),
    );
    expect(seed.descriptors['planarity'], inInclusiveRange(0, 1));
    expect(seed.descriptors['normalCoherence'], 1);
  });

  test(
    'pipeline recognizes plane, creates DNA, explanation, graph and EDE decision',
    () async {
      final decisions = EngineeringDecisionEngine();
      final engine = GeometricRecognitionEngine(
        decisions: DecisionApi(engine: decisions),
      );
      final progress = <double>[];
      final result = await engine.recognize(
        planeContext(),
        onProgress: progress.add,
      );
      expect(result.winner.type, PrimitiveType.plane);
      expect(result.winner.status, RecognitionStatus.validated);
      expect(result.dna.version, '3.0.0');
      expect(result.dna.geometricSignature, contains('mesh:r1'));
      expect(result.explanation.losingCandidates, isA<List<String>>());
      expect(result.explanation.confidence, greaterThan(0));
      expect(engine.graph.engineeringGraph.nodes, contains(result.id));
      expect(decisions.graph.decisions.single.regionId, 'r');
      expect(progress.last, 1);
    },
  );

  test('sphere fitting wins for symmetric sphere samples', () async {
    final context = RecognitionContext(
      observation: RecognitionObservation(
        projectId: 'p',
        meshId: 'sphere',
        regionId: 'sphere-region',
        points: const [
          Vector3(1, 0, 0),
          Vector3(-1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(0, -1, 0),
          Vector3(0, 0, 1),
          Vector3(0, 0, -1),
          Vector3(.707106, .707106, 0),
        ],
        meshFingerprint: 'sphere-mesh',
        regionFingerprint: 'sphere-region',
      ),
    );
    final result = await GeometricRecognitionEngine().recognize(context);
    expect(result.winner.type, PrimitiveType.sphere);
    expect(result.winner.parameters['radius'], closeTo(1, .001));
  });

  test(
    'insufficient observation becomes unknown rather than fabricated',
    () async {
      final context = RecognitionContext(
        observation: RecognitionObservation(
          projectId: 'p',
          meshId: 'm',
          regionId: 'small',
          points: const [Vector3.zero],
          meshFingerprint: 'm',
          regionFingerprint: 'small',
        ),
      );
      final result = await GeometricRecognitionEngine().recognize(context);
      expect(result.winner.type, PrimitiveType.unknown);
      expect(result.dna.confidence, 0);
      expect(result.explanation.why, contains('Nenhum reconhecedor'));
    },
  );

  test('competition ranks candidates and removes type-region duplicates', () {
    RecognitionCandidate candidate(String id, double score) =>
        RecognitionCandidate(
          id: id,
          type: PrimitiveType.plane,
          regionId: 'r',
          parameters: const {},
          statistics: FitStatistics(
            rms: 1 - score,
            maximum: 1,
            mean: .5,
            coverage: score,
            stability: score,
            score: score,
          ),
          evidence: const [],
          origin: id,
        );
    final result = const RecognitionCompetition().resolve([
      candidate('low', .4),
      candidate('high', .9),
    ]);
    expect(result.winner.id, 'high');
    expect(result.rejectedDuplicates.single.id, 'low');
  });

  test('cache key includes fingerprints and parameters', () {
    final cache = RecognitionCache(), context = planeContext();
    final candidate = const PlaneRecognizer().evaluate(context);
    final result = PrimitiveRecognitionResult(
      id: 'id',
      projectId: 'p',
      meshId: 'm',
      winner: candidate,
      alternatives: const [],
      dna: RecognitionDNA(
        type: PrimitiveType.plane,
        parameters: candidate.parameters,
        regionId: 'r',
        geometricSignature: 'dna',
        quality: 1,
        confidence: 1,
        evidence: const [],
        origin: 'test',
        version: '3',
      ),
      explanation: const RecognitionExplanation(
        why: 'test',
        evidence: [],
        regions: ['r'],
        parameters: {},
        losingCandidates: [],
        score: 1,
        confidence: 1,
      ),
      createdAt: DateTime.utc(2026),
    );
    cache.write(context, result);
    expect(cache.read(context), same(result));
    expect(cache.read(planeContext(fingerprint: 'other')), isNull);
  });

  test('confidence fusion uses multiple signals and not RMS alone', () {
    final context = planeContext(),
        candidate = const PlaneRecognizer().evaluate(context);
    final confidence = const RecognitionConfidenceFusion().fuse(
      context,
      candidate,
    );
    expect(confidence, isNot(candidate.statistics.score));
    expect(confidence, inInclusiveRange(0, 1));
  });

  test('plugins and runtime are replaceable infrastructure', () async {
    final plugins = RecognitionPluginRegistry()
      ..register(const PlaneRecognizer());
    expect(() => plugins.register(const PlaneRecognizer()), throwsStateError);
    expect(await const RecognitionRuntime().run('urf-test', () => 42), 42);
  });

  test('replaceable pipeline records successful stages', () async {
    final pipeline = RecognitionPipeline([_Stage()]);
    expect(await pipeline.run(planeContext(), 1), 2);
    expect(pipeline.traces.single.success, isTrue);
  });

  test('FEL exposes complete recognition vocabulary', () {
    final names = createNativeCommandRegistry(Directory.systemTemp).names;
    for (final name in [
      'RECOGNIZE',
      'RECOGNIZE REGION',
      'LIST PRIMITIVES',
      'SHOW CANDIDATES',
      'SHOW CONFIDENCE',
      'EXPLAIN PRIMITIVE',
      'COMPARE PRIMITIVES',
      'VALIDATE PRIMITIVES',
      'REBUILD RECOGNITION',
      'CLEAR RECOGNITION',
    ]) {
      expect(names, contains(name));
    }
  });

  test('cache distinguishes automatic and directed request keys', () {
    final cache = RecognitionCache();
    expect(
      cache.key(planeContext()),
      isNot(cache.key(planeContext(), requestKey: 'types:plane')),
    );
  });

  test('allowedTypes filters recognizers before execution', () async {
    final port = ReceivePort(), messages = <Object?>[];
    final subscription = port.listen(messages.add);
    final plane = _CountingRecognizer(
          PrimitiveType.plane,
          score: .9,
          port: port.sendPort,
        ),
        sphere = _CountingRecognizer(
          PrimitiveType.sphere,
          score: .99,
          port: port.sendPort,
        );
    final plugins = RecognitionPluginRegistry()
      ..register(plane)
      ..register(sphere);
    final result = await GeometricRecognitionEngine(
      plugins: plugins,
    ).recognize(planeContext(), allowedTypes: {PrimitiveType.plane});

    expect(result.winner.type, PrimitiveType.plane);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel();
    port.close();
    expect(messages, ['test.plane']);
    expect(sphere.id, isNotEmpty);
  });

  test('directed request does not reuse an automatic cached result', () async {
    final port = ReceivePort(), messages = <Object?>[];
    final subscription = port.listen(messages.add);
    final plane = _CountingRecognizer(
          PrimitiveType.plane,
          score: .9,
          port: port.sendPort,
        ),
        sphere = _CountingRecognizer(
          PrimitiveType.sphere,
          score: .99,
          port: port.sendPort,
        );
    final engine = GeometricRecognitionEngine(
      plugins: RecognitionPluginRegistry()
        ..register(plane)
        ..register(sphere),
    );
    final automatic = await engine.recognize(planeContext());
    expect(automatic.winner.type, PrimitiveType.sphere);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(messages, containsAll(['test.plane', 'test.sphere']));
    messages.clear();

    final directed = await engine.recognize(
      planeContext(),
      allowedTypes: {PrimitiveType.plane},
    );
    expect(directed.winner.type, PrimitiveType.plane);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel();
    port.close();
    expect(messages, ['test.plane']);
    expect(sphere.id, isNotEmpty);
  });

  test(
    'directed plane uses PlaneRecognizer on ideal and noisy regions',
    () async {
      for (final noise in [0.0, .001]) {
        final context = RecognitionContext(
          observation: RecognitionObservation(
            projectId: 'p',
            meshId: 'directed-plane',
            regionId: 'plane-noise-$noise',
            points: [
              Vector3(0, 0, 2 + noise),
              Vector3(1, 0, 2 - noise),
              Vector3(1, 1, 2 + noise),
              Vector3(0, 1, 2 - noise),
              Vector3(.5, .5, 2 + noise),
            ],
            meshFingerprint: 'directed-plane-mesh',
            regionFingerprint: 'plane-noise-$noise',
          ),
        );
        final result = await GeometricRecognitionEngine().recognize(
          context,
          allowedTypes: {PrimitiveType.plane},
          rebuild: true,
        );
        expect(result.winner.type, PrimitiveType.plane);
        expect(result.alternatives, isEmpty);
        expect(result.winner.statistics.rms, lessThan(.01));
      }
    },
  );

  test('directed plane on a sphere does not become a sphere result', () async {
    final context = RecognitionContext(
      observation: RecognitionObservation(
        projectId: 'p',
        meshId: 'sphere-directed-plane',
        regionId: 'sphere-directed-plane',
        points: const [
          Vector3(1, 0, 0),
          Vector3(-1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(0, -1, 0),
          Vector3(0, 0, 1),
          Vector3(0, 0, -1),
          Vector3(.707106, .707106, 0),
        ],
        meshFingerprint: 'sphere-directed-plane-mesh',
        regionFingerprint: 'sphere-directed-plane',
      ),
    );
    final result = await GeometricRecognitionEngine().recognize(
      context,
      allowedTypes: {PrimitiveType.plane},
      rebuild: true,
    );
    expect(result.winner.type, PrimitiveType.plane);
    expect(result.winner.statistics.rms, greaterThan(.1));
  });
}

class _Stage implements RecognitionPipelineStage<int, int> {
  @override
  String get name => 'test';
  @override
  Future<int> execute(RecognitionContext context, int input) async => input + 1;
}

final class _CountingRecognizer implements UniversalRecognizer {
  _CountingRecognizer(this.type, {required this.score, this.port});

  @override
  final PrimitiveType type;
  final double score;
  final SendPort? port;

  @override
  String get id => 'test.${type.name}';

  @override
  bool detect(RecognitionContext context) => true;

  @override
  RecognitionCandidate evaluate(RecognitionContext context) {
    port?.send(id);
    final parameters = type == PrimitiveType.plane
        ? <String, dynamic>{
            'origin': [0, 0, 0],
            'normal': [0, 0, 1],
          }
        : <String, dynamic>{
            'center': [0, 0, 0],
            'radius': 1.0,
          };
    return RecognitionCandidate(
      id: '$id:${context.observation.regionFingerprint}',
      type: type,
      regionId: context.observation.regionId,
      parameters: parameters,
      statistics: FitStatistics(
        rms: 0,
        maximum: 0,
        mean: 0,
        coverage: 1,
        stability: 1,
        score: score,
      ),
      evidence: const [],
      origin: id,
    );
  }

  @override
  RecognitionCandidate refine(
    RecognitionContext context,
    RecognitionCandidate candidate,
  ) => candidate;

  @override
  bool validate(RecognitionContext context, RecognitionCandidate candidate) =>
      true;

  @override
  RecognitionExplanation explain(
    RecognitionContext context,
    RecognitionCandidate candidate,
    List<RecognitionCandidate> alternatives,
  ) => RecognitionExplanation(
    why: 'test',
    evidence: const [],
    regions: [context.observation.regionId],
    parameters: candidate.parameters,
    losingCandidates: const [],
    score: score,
    confidence: score,
  );

  @override
  double confidence(
    RecognitionContext context,
    RecognitionCandidate candidate,
  ) => score;
}
