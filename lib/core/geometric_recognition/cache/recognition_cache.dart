import '../../engineering/cache/engineering_cache.dart';
import '../models/recognition_models.dart';

class RecognitionCache {
  RecognitionCache({EngineeringCache? cache})
    : _cache = cache ?? EngineeringCache();
  final EngineeringCache _cache;
  String key(RecognitionContext context, {String? requestKey}) =>
      '${context.observation.meshFingerprint}:'
      '${context.observation.regionFingerprint}:${_parameters(context.parameters)}:'
      '${requestKey ?? 'automatic'}';
  PrimitiveRecognitionResult? read(
    RecognitionContext context, {
    String? requestKey,
  }) => _cache.get<PrimitiveRecognitionResult>(
    'geometry',
    key(context, requestKey: requestKey),
    fingerprint: context.observation.regionFingerprint,
    version: 2,
  );
  void write(
    RecognitionContext context,
    PrimitiveRecognitionResult result, {
    String? requestKey,
  }) => _cache.put(
    'geometry',
    key(context, requestKey: requestKey),
    result,
    fingerprint: context.observation.regionFingerprint,
    version: 2,
  );
  void clear() => _cache.invalidateNamespace('geometry');
  String _parameters(Map<String, double> values) {
    final keys = values.keys.toList()..sort();
    return keys.map((key) => '$key=${values[key]}').join(';');
  }
}
