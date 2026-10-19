import '../../geometric_recognition/models/recognition_models.dart';
import '../engine/professional_recognition_engine.dart';
import '../models/professional_recognition_models.dart';

class ProfessionalRecognitionApi {
  ProfessionalRecognitionApi({ProfessionalRecognitionEngine? engine})
    : engine = engine ?? ProfessionalRecognitionEngine();
  final ProfessionalRecognitionEngine engine;
  ProfessionalRecognitionReport? _last;
  Future<ProfessionalRecognitionReport> recognize(
    List<RecognitionContext> regions, {
    Set<PrimitiveType>? allowedTypes,
  }) async =>
      _last = await engine.recognize(regions, allowedTypes: allowedTypes);
  ProfessionalRecognitionReport get last =>
      _last ?? (throw StateError('Professional recognition has not run'));
  String exportReport() =>
      '''{"projectId":"${last.projectId}","primitives":${last.primitives.length},"features":${last.features.length},"confidence":${last.averageConfidence}}''';
}
