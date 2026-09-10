part of 'cad_runtime.dart';

String _assetId(String prefix) {
  final random = math.Random.secure();
  return '${prefix}_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

void _requireId(String value, String prefix) {
  if (!RegExp('^${prefix}_[0-9a-f]{32}\$').hasMatch(value)) {
    throw const FormatException('Invalid durable identifier');
  }
}

/// Serializable reference only; possession never authorizes cleanup.
final class GeometryAssetId {
  GeometryAssetId._(this.value);
  factory GeometryAssetId.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        json.keys.toSet().difference(const {
          'schema',
          'version',
          'id',
        }).isNotEmpty ||
        json['schema'] != 'flcad.geometry-asset' ||
        json['version'] != 1 ||
        json['id'] is! String) {
      throw const FormatException('Invalid asset reference schema');
    }
    final value = json['id'] as String;
    _requireId(value, 'ga1');
    return GeometryAssetId._(value);
  }
  final String value;
  Map<String, dynamic> toJson() => {
    'schema': 'flcad.geometry-asset',
    'version': 1,
    'id': value,
  };
  @override
  bool operator ==(Object other) =>
      other is GeometryAssetId && value == other.value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Durable-only representation for a managed BREP import. This is safe to put
/// in CadDocumentEntity.data: it contains neither native tokens nor CAF
/// capabilities. Each referenced payload has the seal produced by CAF.
final class ManagedBrepAssets {
  ManagedBrepAssets({
    required this.shape,
    required this.display,
    required this.shapeSha256,
    required this.displaySha256,
  }) {
    _requireSha256(shapeSha256, 'managed BREP shape');
    _requireSha256(displaySha256, 'managed BREP display mesh');
  }
  final GeometryAssetId shape, display;
  final String shapeSha256, displaySha256;
  Map<String, dynamic> toJson() => {
    'schema': 'flcad.managed-brep-assets',
    'version': 1,
    'shapeAssetId': shape.toJson(),
    'displayMeshAssetId': display.toJson(),
    'shapeSha256': shapeSha256,
    'displayMeshSha256': displaySha256,
    'meshOnly': false,
  };
  factory ManagedBrepAssets.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference(const {
          'schema',
          'version',
          'shapeAssetId',
          'displayMeshAssetId',
          'shapeSha256',
          'displayMeshSha256',
          'meshOnly',
        }).isNotEmpty ||
        json.length != 7 ||
        json['schema'] != 'flcad.managed-brep-assets' ||
        json['version'] != 1 ||
        json['meshOnly'] != false ||
        json['shapeAssetId'] is! Map ||
        json['displayMeshAssetId'] is! Map ||
        json['shapeSha256'] is! String ||
        json['displayMeshSha256'] is! String) {
      throw const FormatException('Invalid managed BREP asset reference');
    }
    final shapeHash = json['shapeSha256'] as String;
    final displayHash = json['displayMeshSha256'] as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(shapeHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(displayHash)) {
      throw const FormatException('Invalid managed BREP asset hash');
    }
    return ManagedBrepAssets(
      shape: GeometryAssetId.fromJson(
        Map<String, dynamic>.from(json['shapeAssetId'] as Map),
      ),
      display: GeometryAssetId.fromJson(
        Map<String, dynamic>.from(json['displayMeshAssetId'] as Map),
      ),
      shapeSha256: shapeHash,
      displaySha256: displayHash,
    );
  }
}

void _requireSha256(String value, String label) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('Invalid $label asset hash');
  }
}

/// Durable-only representation for a managed STL import. The single payload
/// is both the source-of-truth asset and the display mesh; native residence is
/// deliberately absent from this document contract.
final class ManagedStlAssets {
  ManagedStlAssets({required this.display, required this.displaySha256}) {
    _requireSha256(displaySha256, 'managed STL display mesh');
  }

  final GeometryAssetId display;
  final String displaySha256;

  Map<String, dynamic> toJson() => {
    'schema': 'flcad.managed-stl-assets',
    'version': 1,
    'displayMeshAssetId': display.toJson(),
    'displayMeshSha256': displaySha256,
    'meshOnly': true,
  };

  factory ManagedStlAssets.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference(const {
          'schema',
          'version',
          'displayMeshAssetId',
          'displayMeshSha256',
          'meshOnly',
        }).isNotEmpty ||
        json.length != 5 ||
        json['schema'] != 'flcad.managed-stl-assets' ||
        json['version'] != 1 ||
        json['meshOnly'] != true ||
        json['displayMeshAssetId'] is! Map ||
        json['displayMeshSha256'] is! String) {
      throw const FormatException('Invalid managed STL asset reference');
    }
    return ManagedStlAssets(
      display: GeometryAssetId.fromJson(
        Map<String, dynamic>.from(json['displayMeshAssetId'] as Map),
      ),
      displaySha256: json['displayMeshSha256'] as String,
    );
  }
}

/// Trusted IO seam for deterministic fault injection and streaming instrumentation.
class CadAssetStorage {
  const CadAssetStorage();
  @protected
  Future<void> checkpoint(String phase) async {}
  @protected
  String newAssetId() => _assetId('ga1');
  @protected
  Timer lockTimer(Duration timeout, void Function() expired) =>
      Timer(timeout, expired);
  @protected
  Stream<List<int>> read(File source) => source.openRead();
}

final class _AssetPaths {
  _AssetPaths(this.root) : native = CadAssetNativeFs(root) {
    _dirs[root] = native.root;
  }
  final String root;
  final CadAssetNativeFs native;
  final _dirs = <String, int>{}, _files = <String, int>{};
  // Capture once: releasing local admission must not require another syscall
  // against a root that may have become unreadable/reparsed during the body.
  late final String lockKey = native
      .info(native.root)
      .entries
      .where((e) => e.key != 'size')
      .map((e) => e.value)
      .join(':');
  static Future<_AssetPaths> open(Directory project) async =>
      _AssetPaths(path.absolute(project.path));
  void dispose() => native.dispose();
  String location(List<String> parts) {
    for (final part in parts) {
      if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(part) ||
          part == '.' ||
          part == '..' ||
          part.endsWith('.')) {
        throw const FormatException('Invalid structural path segment');
      }
    }
    return path.joinAll([root, ...parts]);
  }

  List<String> _parts(String target) {
    if (target == root) return [];
    if (!path.isWithin(root, target)) throw StateError('Path escapes project');
    final parts = path.split(path.relative(target, from: root));
    if (parts.any((p) => p == '.' || p == '..')) {
      throw StateError('Invalid path');
    }
    return parts;
  }

  int directory(String target, {void Function()? authorize}) {
    var current = root, id = native.root;
    for (final part in _parts(target)) {
      current = path.join(current, part);
      final cached = _dirs[current];
      if (cached != null) {
        native.info(cached);
        id = cached;
        continue;
      }
      try {
        id = native.child(id, part, directory: true);
      } on CadAssetNativeError catch (e) {
        if (!e.notFound || authorize == null) rethrow;
        authorize();
        try {
          id = native.child(
            id,
            part,
            directory: true,
            create: true,
            pinned: !part.startsWith('ga1_'),
          );
        } on CadAssetNativeError catch (collision) {
          if (!collision.collision) rethrow;
          id = native.child(id, part, directory: true);
        }
      }
      _dirs[current] = id;
    }
    return id;
  }

  Future<void> directories(
    String target, {
    required void Function() authorize,
  }) async {
    directory(target, authorize: authorize);
  }

  Future<void> check(String target) async {
    _parts(target);
    if (_dirs.containsKey(target)) {
      native.info(_dirs[target]!);
    } else if (_files.containsKey(target)) {
      native.info(_files[target]!);
    }
  }

  Future<bool> exists(String target) async {
    try {
      final parent = directory(path.dirname(target));
      return native
          .entries(parent)
          .any(
            (e) => e.name.toLowerCase() == path.basename(target).toLowerCase(),
          );
    } on CadAssetNativeError catch (e) {
      if (e.notFound) return false;
      rethrow;
    }
  }

  _NativeAssetFile file(String target) {
    _parts(target);
    return _NativeAssetFile(this, target);
  }

  int openFile(String target) => _files[target] ??= native.child(
    directory(path.dirname(target)),
    path.basename(target),
  );
  void release(String target) {
    final id = _files.remove(target);
    if (id != null) native.close(id);
  }

  Future<Map<String, dynamic>> digest(String target) async {
    final owned = _files.containsKey(target);
    try {
      return native.info(openFile(target), digest: true);
    } finally {
      if (!owned) release(target);
    }
  }

  Stream<FileSystemEntity> list(
    String target, {
    bool recursive = false,
  }) async* {
    final entries = native.entries(directory(target));
    for (final e in entries) {
      final child = path.join(target, e.name);
      if (e.reparse) {
        yield Link(child);
      } else if (e.directory) {
        yield Directory(child);
        if (recursive) yield* list(child, recursive: true);
      } else {
        yield File(child);
      }
    }
  }

  void rename(String source, String destination) {
    final id = _dirs[source] ?? _files[source];
    if (id == null) throw StateError('Rename requires owned live capability');
    // NTFS requires descendant handles closed for directory promotion. The
    // source directory and its ancestors remain pinned throughout.
    for (final key in _dirs.keys.toList().reversed) {
      if (path.isWithin(source, key)) native.close(_dirs.remove(key)!);
    }
    native.rename(
      id,
      directory(path.dirname(destination)),
      path.basename(destination),
    );

    for (final table in [_dirs, _files]) {
      for (final key in table.keys.toList()) {
        if (key == source || path.isWithin(source, key)) {
          table[key == source
                  ? destination
                  : path.join(destination, path.relative(key, from: source))] =
              table.remove(key)!;
        }
      }
    }
  }

  void retire(String target) {
    if (_files.containsKey(target)) {
      rename(
        target,
        path.join(path.dirname(target), 'retained.${_assetId('j1')}.json'),
      );
    } else {
      throw StateError('Cannot replace unowned journal');
    }
  }

  Future<_VerifiedManagedAsset> openManagedAsset({
    required String projectId,
    required GeometryAssetId asset,
    required CadAssetFile kind,
    required String expectedSha256,
  }) async {
    _requireId(asset.value, 'ga1');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) {
      throw const FormatException('Invalid expected managed asset hash');
    }
    final assetDirectory = location(['CAD', 'Assets', 'v1', asset.value]);
    final descriptorPath = path.join(assetDirectory, 'asset.json');
    final payloadPath = path.join(assetDirectory, kind.relativePath);

    final descriptorId = openFile(descriptorPath);
    final descriptorBefore = native.info(descriptorId, digest: true);
    final decoded = jsonDecode(await file(descriptorPath).readAsString());
    final descriptorAfter = native.info(descriptorId, digest: true);
    if (!_sameAssetIdentity(descriptorAfter, descriptorBefore)) {
      throw StateError('Managed asset descriptor changed while opening');
    }
    if (decoded is! Map) {
      throw const FormatException('Invalid managed asset descriptor');
    }
    final descriptor = Map<String, dynamic>.from(decoded);
    if (descriptor.keys.toSet().difference({
          'schema',
          'version',
          'reference',
          'project',
          'files',
        }).isNotEmpty ||
        descriptor['schema'] != 'flcad.geometry-asset-record' ||
        descriptor['version'] != 1 ||
        descriptor['project'] != projectId ||
        descriptor['reference'] is! Map ||
        descriptor['files'] is! Map) {
      throw const FormatException('Invalid managed asset descriptor');
    }
    final reference = GeometryAssetId.fromJson(
      Map<String, dynamic>.from(descriptor['reference'] as Map),
    );
    if (reference != asset) {
      throw const FormatException('Managed asset reference mismatch');
    }
    final files = Map<String, dynamic>.from(descriptor['files'] as Map);
    if (files.length != 1 || files[kind.name] is! Map) {
      throw const FormatException('Managed asset payload contract mismatch');
    }
    final expected = Map<String, dynamic>.from(files[kind.name] as Map);
    if (expected.keys.toSet().difference({
          'status',
          'size',
          'sha256',
          'allowEmpty',
          'volume',
          'fileId',
        }).isNotEmpty ||
        expected['status'] != 'written' ||
        expected['allowEmpty'] != false ||
        expected['size'] is! int ||
        (expected['size'] as int) <= 0 ||
        expected['sha256'] != expectedSha256 ||
        expected['volume'] is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{1,16}$',
        ).hasMatch(expected['volume'] as String) ||
        expected['fileId'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(expected['fileId'] as String)) {
      throw const FormatException('Invalid managed asset payload metadata');
    }

    final entries = await list(assetDirectory, recursive: true).toList();
    final expectedPaths = {
      path.normalize(descriptorPath),
      path.normalize(payloadPath),
    };
    if (entries.length != expectedPaths.length ||
        entries.any(
          (entry) =>
              entry is! File ||
              !expectedPaths.contains(path.normalize(entry.path)),
        )) {
      throw StateError('Managed asset contains unexpected entries');
    }
    final payloadId = openFile(payloadPath);
    final actual = native.info(payloadId, digest: true);
    if (!_sameAssetIdentity(actual, expected)) {
      throw StateError('Managed asset identity, size or hash diverged');
    }
    return _VerifiedManagedAsset(
      native: native,
      file: payloadId,
      descriptorFile: descriptorId,
      expected: Map<String, dynamic>.unmodifiable(expected),
      descriptorExpected: Map<String, dynamic>.unmodifiable(descriptorBefore),
    );
  }
}

final class _VerifiedManagedAsset {
  const _VerifiedManagedAsset({
    required this.native,
    required this.file,
    required this.descriptorFile,
    required this.expected,
    required this.descriptorExpected,
  });
  final CadAssetNativeFs native;
  final int file, descriptorFile;
  final Map<String, dynamic> expected, descriptorExpected;

  void revalidate() {
    if (!_sameAssetIdentity(native.info(file, digest: true), expected) ||
        !_sameAssetIdentity(
          native.info(descriptorFile, digest: true),
          descriptorExpected,
        )) {
      throw StateError('Managed asset changed before document publication');
    }
  }
}

final class _NativeAssetFile {
  _NativeAssetFile(this.paths, this.path);
  final _AssetPaths paths;
  final String path;
  Directory get parent => Directory(Directory(path).parent.path);
  Future<void> create({required bool exclusive}) async {
    if (!exclusive) throw StateError('Exclusive creation required');
    final id = paths.native.child(
      paths.directory(parent.path),
      File(path).uri.pathSegments.last,
      create: true,
    );
    paths._files[path] = id;
  }

  Future<_NativeAssetFile> open({FileMode? mode}) async {
    paths.openFile(path);
    return this;
  }

  Future<void> writeFrom(List<int> bytes, [int start = 0, int? end]) async {
    paths.native.write(paths.openFile(path), bytes.sublist(start, end));
  }

  Future<void> flush() async {
    paths.native.info(paths.openFile(path), digest: true);
  }

  Future<void> close() async {
    paths.release(path);
  }

  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) async {
    for (var i = 0; i < bytes.length; i += 65536) {
      paths.native.write(
        paths.openFile(path),
        bytes.sublist(i, math.min(i + 65536, bytes.length)),
      );
    }
    if (flush) paths.native.info(paths.openFile(path), digest: true);
  }

  Future<void> writeAsString(String text, {bool flush = false}) =>
      writeAsBytes(utf8.encode(text), flush: flush);
  Future<int> length() async =>
      paths.native.info(paths.openFile(path))['size'] as int;
  Future<String> readAsString() async {
    final borrowed = !paths._files.containsKey(path);
    try {
      final id = paths.openFile(path), bytes = <int>[];
      final size = paths.native.info(id)['size'] as int;
      if (size > 1024 * 1024) {
        throw const FormatException('Manifest exceeds limit');
      }
      for (var offset = 0; offset < size;) {
        final chunk = paths.native.read(
          id,
          offset,
          math.min(65536, size - offset),
        );
        if (chunk.isEmpty) throw const FormatException('Truncated manifest');
        bytes.addAll(chunk);
        offset += chunk.length;
      }
      return utf8.decode(bytes);
    } finally {
      if (borrowed) paths.release(path);
    }
  }

  Future<void> rename(String destination) async {
    paths.rename(path, destination);
  }
}

final class CadAssetCancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  void cancel() {
    if (!isCancelled) _done.complete();
  }
}

final class CadAssetCancelled implements Exception {
  const CadAssetCancelled();
}

final class _ProjectAssetLocks {
  static final held = <String, Completer<void>>{};
  static final zoneKey = Object();

  static Future<T> run<T>(
    _AssetPaths paths,
    String instance,
    String operation,
    Duration timeout,
    Future<void> cancelled,
    void Function() validate,
    CadAssetStorage storage,
    Future<T> Function() body,
  ) async {
    if (RootIsolateToken.instance == null) {
      // File locks are process-scoped on Unix; local admission must have one host.
      // Flutter test isolates also lack a root token, but Windows handle locks
      // provide exclusion across isolates, so that platform remains supported.
      if (!Platform.isWindows) {
        throw StateError('Asset locking requires the root isolate');
      }
    }
    if ((Zone.current[zoneKey] as Set<String>?)?.contains(paths.lockKey) ??
        false) {
      throw StateError('Reentrant project lock');
    }
    if (timeout <= Duration.zero) {
      throw TimeoutException('Project asset lock timed out', timeout);
    }
    final elapsed = Stopwatch()..start();
    final expired = Completer<void>();
    final timer = storage.lockTimer(timeout, () => expired.complete());
    Future<void> wait(Future<void> available) async {
      final reason = await Future.any<int>([
        available.then((_) => 0),
        cancelled.then((_) => 1),
        expired.future.then((_) => 2),
      ]);
      if (reason == 1) throw const CadAssetCancelled();
      if (reason == 2) {
        throw TimeoutException('Project asset lock timed out', timeout);
      }
      validate();
      if (expired.isCompleted || elapsed.elapsed >= timeout) {
        throw TimeoutException('Project asset lock timed out', timeout);
      }
    }

    int? handle;
    Completer<void>? local;
    var locked = false;
    try {
      while (true) {
        validate();
        if (expired.isCompleted || elapsed.elapsed >= timeout) {
          throw TimeoutException('Project asset lock timed out', timeout);
        }
        final incumbent = held[paths.lockKey];
        if (incumbent != null) {
          await storage.checkpoint('lock:contended');
          await wait(incumbent.future);
          continue;
        }
        local = Completer<void>();
        held[paths.lockKey] = local;
        final lockPath = paths.location(['.cad-staging', 'project.lock']);
        await paths.directories(path.dirname(lockPath), authorize: validate);
        await paths.check(lockPath);
        validate();
        try {
          try {
            handle = paths.native.child(
              paths.directory(path.dirname(lockPath)),
              'project.lock',
              create: true,
            );
          } on CadAssetNativeError catch (e) {
            if (!e.collision) rethrow;
            handle = paths.native.child(
              paths.directory(path.dirname(lockPath)),
              'project.lock',
            );
          }
          paths.native.lock(handle);
          locked = true;
          break;
        } on CadAssetNativeError catch (error) {
          if (handle != null) paths.native.close(handle);
          handle = null;
          held.remove(paths.lockKey);
          local.complete();
          local = null;
          if (!error.contention) rethrow;
          await storage.checkpoint('lock:contended');
          // Cross-process locks have no Dart notification API. Bounded polling
          // is only the fallback; tests synchronize using contention barriers.
          await wait(Future<void>.delayed(const Duration(milliseconds: 20)));
        }
      }
      validate();
      if (expired.isCompleted || elapsed.elapsed >= timeout) {
        throw TimeoutException('Project asset lock timed out', timeout);
      }
      timer.cancel();
      await storage.checkpoint('lock:acquired');
      validate();
      return await runZoned(
        body,
        zoneValues: {
          zoneKey: {...?Zone.current[zoneKey] as Set<String>?, paths.lockKey},
        },
      );
    } finally {
      timer.cancel();
      try {
        if (locked && handle != null) {
          paths.native.close(handle);
          handle = null;
        }
      } finally {
        try {
          if (handle != null) paths.native.close(handle);
        } finally {
          if (local != null) {
            held.remove(paths.lockKey);
            local.complete();
          }
        }
      }
    }
  }
}

String _manifestChecksum(Map<String, dynamic> data) =>
    sha256.convert(utf8.encode(jsonEncode(data))).toString();

Future<Map<String, dynamic>> _readAssetManifest(
  _NativeAssetFile file,
  _AssetPaths paths,
  String instance,
  String operation,
) async {
  await paths.check(file.path);
  if (await file.length() > 1024 * 1024) {
    throw const FormatException('Manifest exceeds limit');
  }
  final envelope =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final data = envelope['data'] as Map<String, dynamic>;
  if (envelope['checksum'] != _manifestChecksum(data) ||
      data['schema'] != 'flcad.geometry-staging' ||
      data['version'] != 1 ||
      data['instance'] != instance ||
      data['operation'] != operation ||
      (data.containsKey('root') && data['root'] != paths.root) ||
      data['project'] is! String ||
      data['session'] is! int ||
      data['revision'] is! int ||
      data['transaction'] is! int ||
      data['sequence'] is! int ||
      !CadAssetStageState.values.any((s) => s.name == data['state']) ||
      data['assets'] is! List ||
      data['promoted'] is! List ||
      data['failures'] is! List) {
    throw const FormatException('Invalid manifest identity or checksum');
  }
  _requireId(instance, 'i1');
  _requireId(operation, 'o1');
  const fields = {
    'schema',
    'version',
    'instance',
    'operation',
    'project',
    'root',
    'session',
    'revision',
    'transaction',
    'state',
    'sequence',
    'createdAt',
    'updatedAt',
    'assets',
    'promoted',
    'failures',
    'quarantineReason',
    'documentPublished',
  };
  if (data.keys.any((k) => !fields.contains(k)) ||
      data['documentPublished'] is! bool ||
      (data['documentPublished'] == true && data['state'] != 'committed') ||
      DateTime.tryParse(data['createdAt'] as String? ?? '') == null ||
      DateTime.tryParse(data['updatedAt'] as String? ?? '') == null ||
      (data['sequence'] as int) < 0) {
    throw const FormatException('Invalid journal metadata');
  }
  final prepared = [
    'prepared',
    'commitIntent',
    'promoting',
    'committed',
  ].contains(data['state']);
  bool validDigest(Map info) =>
      info['size'] is int &&
      (info['size'] as int) >= 0 &&
      info['sha256'] is String &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(info['sha256'] as String);
  final ids = <String>{};
  for (final raw in data['assets'] as List) {
    final asset = raw as Map<String, dynamic>;
    final id = GeometryAssetId.fromJson(
      asset['reference'] as Map<String, dynamic>,
    );
    if (!ids.add(id.value)) throw const FormatException('Duplicate asset');
    final files = asset['files'] as Map<String, dynamic>;
    if (asset.keys.any(
          (k) => !{'reference', 'files', 'descriptor'}.contains(k),
        ) ||
        (prepared &&
            (files.isEmpty ||
                asset['descriptor'] is! Map ||
                !validDigest(asset['descriptor'] as Map)))) {
      throw const FormatException('Invalid prepared asset');
    }
    for (final entry in files.entries) {
      if (!CadAssetFile.values.any((v) => v.name == entry.key)) {
        throw const FormatException('Unknown asset file');
      }
      final info = entry.value as Map<String, dynamic>;
      if (info['allowEmpty'] is! bool ||
          info.keys.any(
            (k) => !{
              'status',
              'size',
              'sha256',
              'allowEmpty',
              'volume',
              'fileId',
            }.contains(k),
          )) {
        throw const FormatException('Invalid file metadata');
      }
      if (info['status'] == 'written') {
        if (info['size'] is! int ||
            (info['size'] as int) < 0 ||
            info['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(info['sha256'] as String)) {
          throw const FormatException('Invalid file digest');
        }
        if (info['size'] == 0 &&
            (info['allowEmpty'] != true ||
                ['brep', 'display'].contains(entry.key))) {
          throw const FormatException('Empty geometry payload');
        }
      } else if (info['status'] != 'writing') {
        throw const FormatException('Invalid acquired file state');
      } else if (prepared) {
        throw const FormatException(
          'Prepared journal contains incomplete file',
        );
      }
    }
  }
  if ((data['promoted'] as List).any((id) => !ids.contains(id))) {
    throw const FormatException('Unknown promoted asset');
  }
  final promoted = data['promoted'] as List;
  if (promoted.toSet().length != promoted.length ||
      (prepared && ids.isEmpty) ||
      (data['state'] == 'committed' && promoted.length != ids.length) ||
      ([
            'preparing',
            'prepared',
            'commitIntent',
            'rollingBack',
            'rolledBack',
          ].contains(data['state']) &&
          promoted.isNotEmpty)) {
    throw const FormatException('Journal promotion state is inconsistent');
  }
  return data;
}
