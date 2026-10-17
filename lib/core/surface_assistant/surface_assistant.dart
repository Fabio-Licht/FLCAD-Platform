import '../recognition_engine/recognition_result.dart';

enum SurfaceAssistantStrategy {
  planarSurface,
  cylindricalSurface,
  conicalSurface,
  sphericalSurface,
  filletSurface,
  freeSurface,
  loft,
  sweep,
  networkSurface,
}

enum SurfaceAssistantDecision { pending, ignored, confirmed }

class SurfaceAssistantSuggestion {
  const SurfaceAssistantSuggestion({
    required this.recognitionResultId,
    required this.type,
    required this.confidence,
    required this.parameters,
    required this.quality,
    required this.strategy,
    required this.alternatives,
    required this.canCreate,
  });

  final String recognitionResultId;
  final RecognitionResultType type;
  final double confidence;
  final Map<String, dynamic> parameters;
  final String quality;
  final SurfaceAssistantStrategy strategy;
  final List<SurfaceAssistantStrategy> alternatives;
  final bool canCreate;

  String get title => switch (type) {
    RecognitionResultType.plane => 'Recognized Plane',
    RecognitionResultType.cylinder => 'Recognized Cylinder',
    RecognitionResultType.cone => 'Recognized Cone',
    RecognitionResultType.sphere => 'Recognized Sphere',
    RecognitionResultType.fillet => 'Fillet detected',
    RecognitionResultType.freeform => 'Freeform region',
  };
}

/// Pure consumer of Recognition Result. It never receives mesh data and has
/// no dependency on CAD generation, persistence, Sketch or Surface modules.
class IntelligentSurfaceAssistant {
  const IntelligentSurfaceAssistant({this.approvedConfidence = .65});
  final double approvedConfidence;

  SurfaceAssistantSuggestion suggest(RecognitionResult result) {
    final strategy = switch (result.type) {
      RecognitionResultType.plane => SurfaceAssistantStrategy.planarSurface,
      RecognitionResultType.cylinder =>
        SurfaceAssistantStrategy.cylindricalSurface,
      RecognitionResultType.cone => SurfaceAssistantStrategy.conicalSurface,
      RecognitionResultType.sphere => SurfaceAssistantStrategy.sphericalSurface,
      RecognitionResultType.fillet => SurfaceAssistantStrategy.filletSurface,
      RecognitionResultType.freeform => SurfaceAssistantStrategy.freeSurface,
    };
    final alternatives = result.type == RecognitionResultType.freeform
        ? const [
            SurfaceAssistantStrategy.loft,
            SurfaceAssistantStrategy.sweep,
            SurfaceAssistantStrategy.networkSurface,
          ]
        : const <SurfaceAssistantStrategy>[];
    return SurfaceAssistantSuggestion(
      recognitionResultId: result.id,
      type: result.type,
      confidence: result.confidence,
      parameters: Map.unmodifiable(result.parameters),
      quality: result.quality,
      strategy: strategy,
      alternatives: alternatives,
      canCreate:
          result.type != RecognitionResultType.freeform &&
          (result.type != RecognitionResultType.plane ||
              result.parameters['cadSurfaceApproved'] == true) &&
          result.parameters['dimensionalApproved'] != false &&
          result.confidence >= approvedConfidence,
    );
  }
}
