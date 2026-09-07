import 'dart:io';

import 'package:path/path.dart' as path;

const colmapSupportedImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.tif',
  '.tiff',
  '.bmp',
  '.webp',
};

typedef ColmapCanonicalPathResolver = Future<String> Function(String value);

class ValidatedColmapPhotoDirectory {
  ValidatedColmapPhotoDirectory({
    required this.canonicalPath,
    required Iterable<String> canonicalImagePaths,
  }) : canonicalImagePaths = List.unmodifiable(canonicalImagePaths);

  final String canonicalPath;
  final List<String> canonicalImagePaths;

  int get imageCount => canonicalImagePaths.length;
}

abstract interface class ColmapInputValidator {
  Future<ValidatedColmapPhotoDirectory> validatePhotoDirectory(String value);

  Future<String> prepareWorkspaceRoot(String value);
}

class IoColmapInputValidator implements ColmapInputValidator {
  const IoColmapInputValidator({
    ColmapCanonicalPathResolver? canonicalPathResolver,
  }) : _canonicalPathResolver = canonicalPathResolver;

  final ColmapCanonicalPathResolver? _canonicalPathResolver;

  @override
  Future<ValidatedColmapPhotoDirectory> validatePhotoDirectory(
    String value,
  ) async {
    if (!path.isAbsolute(value)) {
      throw ArgumentError.value(value, 'imagePath', 'must be absolute');
    }
    final directory = Directory(value);
    if (!await directory.exists()) {
      throw ArgumentError.value(value, 'imagePath', 'does not exist');
    }
    final canonicalDirectory = await _canonicalize(directory.absolute.path);
    if (!path.isAbsolute(canonicalDirectory)) {
      throw StateError('Canonical image directory is not absolute');
    }

    final images = <String>[];
    final identities = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File && entity is! Link) continue;
      if (!colmapSupportedImageExtensions.contains(
        path.extension(entity.path).toLowerCase(),
      )) {
        continue;
      }
      final canonicalImage = await _canonicalize(entity.absolute.path);
      final image = File(canonicalImage);
      if (!await image.exists()) {
        throw ArgumentError.value(
          entity.path,
          'imagePath',
          'does not identify an existing file',
        );
      }
      if (!_samePath(path.dirname(canonicalImage), canonicalDirectory)) {
        throw ArgumentError.value(
          entity.path,
          'imagePath',
          'escapes the selected directory',
        );
      }
      final identity = _identity(canonicalImage);
      if (!identities.add(identity)) {
        throw ArgumentError.value(
          entity.path,
          'imagePath',
          'duplicates a canonical image path',
        );
      }
      images.add(canonicalImage);
    }
    if (images.isEmpty) {
      throw ArgumentError.value(
        value,
        'imagePath',
        'does not contain a supported image',
      );
    }
    images.sort((left, right) => _identity(left).compareTo(_identity(right)));
    return ValidatedColmapPhotoDirectory(
      canonicalPath: canonicalDirectory,
      canonicalImagePaths: images,
    );
  }

  @override
  Future<String> prepareWorkspaceRoot(String value) async {
    if (!path.isAbsolute(value)) {
      throw ArgumentError.value(value, 'workspacePath', 'must be absolute');
    }
    final directory = Directory(value);
    await directory.create(recursive: true);
    final canonical = await _canonicalize(directory.absolute.path);
    if (!path.isAbsolute(canonical) || !await Directory(canonical).exists()) {
      throw StateError('Managed COLMAP workspace root is unavailable');
    }
    return canonical;
  }

  Future<String> _canonicalize(String value) =>
      _canonicalPathResolver?.call(value) ?? File(value).resolveSymbolicLinks();

  static bool _samePath(String left, String right) =>
      _identity(left) == _identity(right);

  static String _identity(String value) {
    final normalized = path.normalize(path.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
