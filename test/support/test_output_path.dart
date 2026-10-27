import 'dart:io';

/// Routes legacy absolute diagnostic artifacts into a disposable test root
/// when requested, while keeping real fixture input paths unchanged.
String testOutputPath(String originalPath, {String? outputRoot}) {
  final root = outputRoot ?? Platform.environment['FLCAD_TEST_OUTPUT_ROOT'];
  if (root == null || root.isEmpty) return originalPath;

  const protectedRoot = r'C:\flcad_mobile';
  final normalized = originalPath.replaceAll('/', r'\');
  final lowerPath = normalized.toLowerCase();
  final lowerRoot = protectedRoot.toLowerCase();
  if (lowerPath != lowerRoot &&
      !lowerPath.startsWith('$lowerRoot\\')) {
    return originalPath;
  }
  final relative = normalized.length == protectedRoot.length
      ? ''
      : normalized.substring(protectedRoot.length + 1);
  final platformRelative = relative.replaceAll('\\', Platform.pathSeparator);
  return platformRelative.isEmpty
      ? root
      : '$root${Platform.pathSeparator}$platformRelative';
}
