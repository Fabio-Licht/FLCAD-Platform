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
    if (json['schema'] != 'flcad.geometry-asset' ||
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

  Future<Map<String, dynamic>> _digest(File file) async {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    var size = 0;
    await for (final chunk in read(file)) {
      size += chunk.length;
      input.add(chunk);
    }
    input.close();
    return {'size': size, 'sha256': output.value.toString()};
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final class _AssetPaths {
  _AssetPaths(this.root);
  final String root;
  String get lockKey => Platform.isWindows ? root.toLowerCase() : root;
  static Future<_AssetPaths> open(Directory project) async {
    final absolute = path.normalize(path.absolute(project.path));
    final resolved = path.normalize(await project.resolveSymbolicLinks());
    if (!_same(absolute, resolved)) {
      throw StateError('Project root is redirected');
    }
    final result = _AssetPaths(resolved);
    await result.check(resolved);
    return result;
  }

  static bool _same(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

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

  Future<void> check(String target) async {
    final absolute = path.normalize(path.absolute(target));
    if (!_same(root, absolute) && !path.isWithin(root, absolute)) {
      throw StateError('Path escapes project');
    }
    var current = root;
    final segments = _same(root, absolute)
        ? <String>[]
        : path.split(path.relative(absolute, from: root));
    for (final segment in <String>['', ...segments]) {
      if (segment.isNotEmpty) current = path.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Linked path is not permitted');
      }
      if (type == FileSystemEntityType.notFound) continue;
      final resolved = path.normalize(
        await (type == FileSystemEntityType.directory
            ? Directory(current).resolveSymbolicLinks()
            : File(current).resolveSymbolicLinks()),
      );
      if (!_same(current, resolved)) {
        throw StateError('Reparse or redirected path is not permitted');
      }
    }
  }

  Future<void> directories(
    String target, {
    required void Function() authorize,
  }) async {
    await check(target);
    var current = root;
    for (final segment in path.split(path.relative(target, from: root))) {
      current = path.join(current, segment);
      await check(current);
      authorize();
      await Directory(current).create();
      await check(current);
    }
  }

  Future<bool> exists(String target) async {
    await check(target);
    return await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound;
  }
}

/// OS no-replace primitive: unlike Directory.rename this never replaces an
/// existing directory, even an empty one. No OpenCascade ABI is involved.
void _renameAssetNoReplace(String source, String destination) {
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Atomic no-replace asset promotion currently requires Windows',
    );
  }
  final library = ffi.DynamicLibrary.open('kernel32.dll');
  final move = library
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>, ffi.Uint32),
        int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>, int)
      >('MoveFileExW');
  final getError = library
      .lookupFunction<ffi.Uint32 Function(), int Function()>('GetLastError');
  final from = source.toNativeUtf16(), to = destination.toNativeUtf16();
  try {
    // WRITE_THROUGH only; deliberately omit REPLACE_EXISTING and COPY_ALLOWED.
    if (move(from, to, 8) == 0) {
      throw FileSystemException(
        'No-replace promotion failed',
        destination,
        OSError('MoveFileExW', getError()),
      );
    }
  } finally {
    calloc.free(from);
    calloc.free(to);
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

    RandomAccessFile? handle;
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
        handle = await File(lockPath).open(mode: FileMode.append);
        try {
          await handle.lock(FileLock.exclusive, 0, 1);
          locked = true;
          break;
        } on FileSystemException catch (error) {
          await handle.close();
          handle = null;
          held.remove(paths.lockKey);
          local.complete();
          local = null;
          if (![11, 13, 33, 35].contains(error.osError?.errorCode)) rethrow;
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
      final bytes = utf8.encode(
        jsonEncode({
          'schema': 'flcad.asset-lock',
          'version': 1,
          'instance': instance,
          'operation': operation,
        }),
      );
      await handle.setPosition(0);
      await handle.writeFrom(bytes);
      await handle.truncate(bytes.length);
      await handle.flush();
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
        if (locked) await handle!.unlock(0, 1);
      } finally {
        try {
          await handle?.close();
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
  File file,
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
      data['root'] != paths.root ||
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
      data['documentPublished'] != false ||
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
            (k) => !{'status', 'size', 'sha256', 'allowEmpty'}.contains(k),
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
