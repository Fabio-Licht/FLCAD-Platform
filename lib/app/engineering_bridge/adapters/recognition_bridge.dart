import '../../../core/geometric_recognition/models/recognition_models.dart';
import '../../../core/professional_recognition/api/professional_recognition_api.dart';
import '../../../core/professional_recognition/models/professional_recognition_models.dart';
import '../contracts/bridge_context.dart';
import '../contracts/bridge_validation.dart';

class RecognitionBridge {
  const RecognitionBridge(
    this.api, {
    this.validation = const BridgeValidation(),
  });
  final ProfessionalRecognitionApi api;
  final BridgeValidation validation;
  RecognitionContext contextFor(BridgeContext context) {
    validation.requireRegion(context);
    final region = context.region!;
    return RecognitionContext(
      observation: RecognitionObservation(
        projectId: context.projectId,
        meshId: context.meshId,
        regionId: region.id,
        points: region.points,
        normals: region.normals,
        adjacency: region.connectivity,
        meshFingerprint: context.meshFingerprint,
        regionFingerprint: region.fingerprint,
      ),
      parameters:
          (context.attributes['recognitionParameters'] as Map?)
              ?.cast<String, double>() ??
          const {},
    );
  }

  Future<ProfessionalRecognitionReport> recognize(
    BridgeContext context, {
    Set<PrimitiveType>? allowedTypes,
  }) => api.recognize([contextFor(context)], allowedTypes: allowedTypes);
}
