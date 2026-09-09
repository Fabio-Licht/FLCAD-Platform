part of 'cad_runtime.dart';

enum CadAssetStageState {
  preparing,
  prepared,
  commitIntent,
  promoting,
  committed,
  rollingBack,
  rolledBack,
  quarantined,
}

enum CadAssetFile {
  brep('shape.brep'),
  display('display.stl'),
  source('source/original.bin'),
  metadata('metadata.json');

  const CadAssetFile(this.relativePath);
  final String relativePath;
}

final class PreparedGeometryAssets {
  PreparedGeometryAssets._(
    this.projectId,
    this.operationId,
    List<GeometryAssetId> assets,
  ) : assets = List.unmodifiable(assets);
  final String projectId, operationId;
  final List<GeometryAssetId> assets;
  bool get documentPublished => false;
}

final class CadAssetOperationFailure implements Exception {
  CadAssetOperationFailure(this.cause, this.cleanup);
  final Object cause, cleanup;
}

extension CadGeometryStaging on CadRuntime {
  /// Opt-in transaction scope. No document, scene, history or producer is changed.
  Future<T> withGeometryStaging<T>(
    Future<T> Function(CadGeometryStagingOperation) action, {
    CadAssetCancellation? cancellation,
    Duration lockTimeout = const Duration(seconds: 10),
  }) async {
    late T result;
    await _enqueue((tx) async {
      tx.validate();
      if (tx.directory == null || tx.document == null) {
        throw StateError('No active project');
      }
      final paths = await _AssetPaths.open(tx.directory!);
      tx.validate();
      final operation = CadGeometryStagingOperation._(
        tx,
        paths,
        _assetInstance,
        _assetId('o1'),
        _assetStorage,
        cancellation ?? CadAssetCancellation(),
        lockTimeout,
      );
      try {
        await operation._start();
        result = await action(operation);
        operation._accepting = false;
        await operation._tail;
        operation._validate();
        if (operation._failure case final error?) throw error;
        // Returning from a scope revokes promotion authority even if its project
        // revision remains unchanged. Unpromoted staging is retained/rolled back.
        await operation._finish(success: true);
      } catch (error) {
        operation._accepting = false;
        await operation._tail;
        try {
          await operation._finish(success: false);
        } catch (cleanup) {
          throw CadAssetOperationFailure(error, cleanup);
        }
        rethrow;
      } finally {
        operation._accepting = false;
        operation._active = false;
      }
    });
    return result;
  }
}

final class CadGeometryStagingOperation {
  static final _bodyZone = Object();
  CadGeometryStagingOperation._(
    this._tx,
    this._paths,
    this.instanceId,
    this.operationId,
    this._storage,
    this._cancellation,
    this._lockTimeout,
  );
  final _CadTransaction _tx;
  final _AssetPaths _paths;
  final CadAssetStorage _storage;
  final CadAssetCancellation _cancellation;
  final Duration _lockTimeout;
  final String instanceId, operationId;
  final _planned = <GeometryAssetId>[];
  final _shapes = <OwnedNativeShape>[];
  final _meshes = <OwnedNativeMesh>[];
  bool _active = true, _accepting = true;
  Future<void> _tail = Future.value();
  Future<void>? _finishing;
  Object? _failure;
  Map<String, dynamic>? _manifest;
  CadAssetStageState get state => CadAssetStageState.values.byName(
    _manifest?['state'] as String? ?? 'preparing',
  );
  String get stagingDirectory =>
      _paths.location(['.cad-staging', instanceId, operationId]);
  String _assetDirectory(GeometryAssetId asset, {bool finalPath = false}) =>
      finalPath
      ? _paths.location(['CAD', 'Assets', 'v1', asset.value])
      : path.join(stagingDirectory, 'files', asset.value);

  void _validate() {
    if (!_active || _cancellation.isCancelled) throw const CadAssetCancelled();
    _tx.validate();
  }

  void _admission() {
    if (!_accepting) throw StateError('Staging scope is revoked');
    _validate();
  }

  void _preparing() {
    if (state != CadAssetStageState.preparing) {
      throw StateError('Staging is no longer preparing');
    }
  }

  Future<T> _run<T>(Future<T> Function() body) {
    try {
      _admission();
      if (identical(Zone.current[_bodyZone], this)) {
        throw StateError('Reentrant staging operation');
      }
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    final result = _tail.then((_) async {
      try {
        _validate();
        if (_failure != null) throw StateError('Staging already failed');
        return await runZoned(body, zoneValues: {_bodyZone: this});
      } catch (error) {
        _failure ??= error;
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _start() async {
    _validate();
    if (await _paths.exists(stagingDirectory)) {
      throw StateError('Operation directory collision');
    }
    await _paths.directories(path.join(stagingDirectory, 'files'));
    _validate();
    final now = DateTime.now().toUtc().toIso8601String();
    await _writeManifest({
      'schema': 'flcad.geometry-staging',
      'version': 1,
      'instance': instanceId,
      'operation': operationId,
      'project': _tx.document!.projectId,
      'root': _paths.root,
      'session': _tx.session,
      'revision': _tx.revision,
      'transaction': _tx.id,
      'state': 'preparing',
      'sequence': 0,
      'createdAt': now,
      'updatedAt': now,
      'assets': <dynamic>[],
      'promoted': <dynamic>[],
      'failures': <dynamic>[],
      'quarantineReason': null,
      'documentPublished': false,
    });
  }

  Future<GeometryAssetId> planAsset() => _run(() async {
    _preparing();
    final asset = GeometryAssetId._(_assetId('ga1'));
    if (await _paths.exists(_assetDirectory(asset)) ||
        await _paths.exists(_assetDirectory(asset, finalPath: true))) {
      throw StateError('Asset ID collision');
    }
    final next = _copy();
    (next['assets'] as List).add({
      'reference': asset.toJson(),
      'files': <String, dynamic>{},
    });
    await _update(next, CadAssetStageState.preparing);
    _planned.add(asset);
    await _paths.directories(_assetDirectory(asset));
    return asset;
  });

  Map<String, dynamic> _asset(
    Map<String, dynamic> manifest,
    GeometryAssetId asset,
  ) {
    if (!_planned.any((id) => identical(id, asset))) {
      throw StateError('Asset is not owned by this operation');
    }
    return (manifest['assets'] as List).cast<Map<String, dynamic>>().firstWhere(
      (a) => (a['reference'] as Map)['id'] == asset.value,
    );
  }

  Future<void> write(
    GeometryAssetId asset,
    CadAssetFile kind,
    Stream<List<int>> bytes, {
    bool allowEmpty = false,
  }) => _run(() async {
    _preparing();
    if (allowEmpty &&
        (kind == CadAssetFile.brep || kind == CadAssetFile.display)) {
      throw ArgumentError('Geometry payloads cannot allow empty files');
    }
    final next = _copy();
    final files = _asset(next, asset)['files'] as Map<String, dynamic>;
    if (files.containsKey(kind.name)) {
      throw StateError('Asset file already acquired');
    }
    files[kind.name] = {'status': 'writing', 'allowEmpty': allowEmpty};
    await _update(next, CadAssetStageState.preparing);
    final target = File(path.join(_assetDirectory(asset), kind.relativePath));
    await _paths.directories(target.parent.path);
    await _paths.check(target.path);
    await target.create(exclusive: true);
    final file = await target.open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in bytes) {
        _validate();
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          await file.writeFrom(
            chunk,
            offset,
            math.min(offset + 65536, chunk.length),
          );
        }
      }
      await file.flush();
    } finally {
      await file.close();
    }
    await _storage.checkpoint('file:flushed');
    _validate();
    await _paths.check(target.path);
    final digest = await _storage._digest(target);
    if (digest['size'] == 0 && !allowEmpty) {
      throw StateError('Empty asset payload');
    }
    final complete = _copy();
    (_asset(complete, asset)['files'] as Map)[kind.name] = {
      ...digest,
      'status': 'written',
      'allowEmpty': allowEmpty,
    };
    await _update(complete, CadAssetStageState.preparing);
  });

  /// External source is borrowed: only its byte stream enters the owned stage.
  Future<void> copySource(GeometryAssetId asset, File source) =>
      write(asset, CadAssetFile.source, _storage.read(source));

  void attachOwnedShape(OwnedNativeShape owner) {
    _admission();
    _preparing();
    _shapes.add(owner.transfer());
  }

  void attachOwnedMesh(OwnedNativeMesh owner) {
    _admission();
    _preparing();
    _meshes.add(owner.transfer());
  }

  Future<void> prepare() => _run(() async {
    _preparing();
    if (_planned.isEmpty) throw StateError('No planned assets');
    final next = _copy();
    for (final asset in _planned) {
      final record = _asset(next, asset);
      if ((record['files'] as Map).isEmpty) {
        throw StateError('Asset has no files');
      }
      await _verifyFiles(asset, record, finalPath: false, descriptor: false);
      final descriptor = File(path.join(_assetDirectory(asset), 'asset.json'));
      await _paths.check(descriptor.path);
      await descriptor.create(exclusive: true);
      await descriptor.writeAsString(
        jsonEncode({
          'schema': 'flcad.geometry-asset-record',
          'version': 1,
          'reference': asset.toJson(),
          'project': _tx.document!.projectId,
          'files': record['files'],
        }),
        flush: true,
      );
      record['descriptor'] = await _storage._digest(descriptor);
    }
    await _update(next, CadAssetStageState.prepared);
  });

  Future<PreparedGeometryAssets> promote() => _run(() async {
    if (state != CadAssetStageState.prepared) {
      throw StateError('Only prepared staging may commit');
    }
    final cancellation = Future.any<void>([
      _cancellation._done.future,
      _tx.owner._assetShutdown.future,
    ]);
    return _ProjectAssetLocks.run(
      _paths,
      instanceId,
      operationId,
      _lockTimeout,
      cancellation,
      _validate,
      _storage,
      () async {
        _validate();
        for (final asset in _planned) {
          await _verifyFiles(
            asset,
            _asset(_manifest!, asset),
            finalPath: false,
          );
          if (await _paths.exists(_assetDirectory(asset, finalPath: true))) {
            throw StateError('Asset destination exists');
          }
        }
        await _storage.checkpoint('promotion:beforeIntent');
        _validate();
        await _update(_copy(), CadAssetStageState.commitIntent);
        await _storage.checkpoint('promotion:afterIntent');
        _validate();
        await _update(_copy(), CadAssetStageState.promoting);
        for (final asset in _planned) {
          final source = _assetDirectory(asset),
              destination = _assetDirectory(asset, finalPath: true);
          await _paths.directories(path.dirname(destination));
          await _storage.checkpoint('promotion:beforeMove');
          _validate();
          await _verifyFiles(
            asset,
            _asset(_manifest!, asset),
            finalPath: false,
          );
          await _paths.check(source);
          await _paths.check(destination);
          if (await _paths.exists(destination)) {
            throw StateError('Asset destination collision');
          }
          _validate();
          _renameAssetNoReplace(source, destination);
          await _verifyFiles(asset, _asset(_manifest!, asset), finalPath: true);
          await _storage.checkpoint('promotion:afterMove');
          final next = _copy();
          (next['promoted'] as List).add(asset.value);
          await _update(next, CadAssetStageState.promoting);
        }
        _validate();
        await _update(_copy(), CadAssetStageState.committed);
        return PreparedGeometryAssets._(
          _tx.document!.projectId,
          operationId,
          _planned,
        );
      },
    );
  });

  Future<void> _verifyFiles(
    GeometryAssetId asset,
    Map<String, dynamic> record, {
    required bool finalPath,
    bool descriptor = true,
  }) async {
    final directory = _assetDirectory(asset, finalPath: finalPath);
    await _paths.check(directory);
    final expected = <String>{};
    for (final entry in (record['files'] as Map<String, dynamic>).entries) {
      final kind = CadAssetFile.values.byName(entry.key);
      final info = entry.value as Map<String, dynamic>;
      if (info['status'] != 'written') {
        throw StateError('Incomplete acquired payload');
      }
      final file = File(path.join(directory, kind.relativePath));
      expected.add(path.normalize(file.path));
      await _paths.check(file.path);
      final digest = await _storage._digest(file);
      if (digest['size'] != info['size'] ||
          digest['sha256'] != info['sha256']) {
        throw StateError('Payload changed after validation');
      }
    }
    if (descriptor) {
      final file = File(path.join(directory, 'asset.json'));
      expected.add(path.normalize(file.path));
      await _paths.check(file.path);
      final digest = await _storage._digest(file),
          info = record['descriptor'] as Map;
      if (digest['size'] != info['size'] ||
          digest['sha256'] != info['sha256']) {
        throw StateError('Asset descriptor changed');
      }
    }
    await for (final entry in Directory(
      directory,
    ).list(recursive: true, followLinks: false)) {
      await _paths.check(entry.path);
      if (entry is! Directory &&
          !expected.contains(path.normalize(entry.path))) {
        throw StateError('Unowned file in staging asset');
      }
    }
  }

  Map<String, dynamic> _copy() =>
      jsonDecode(jsonEncode(_manifest)) as Map<String, dynamic>;
  static const _transitions = <CadAssetStageState, Set<CadAssetStageState>>{
    CadAssetStageState.preparing: {
      CadAssetStageState.preparing,
      CadAssetStageState.prepared,
      CadAssetStageState.rollingBack,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.prepared: {
      CadAssetStageState.commitIntent,
      CadAssetStageState.rollingBack,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.commitIntent: {
      CadAssetStageState.promoting,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.promoting: {
      CadAssetStageState.promoting,
      CadAssetStageState.committed,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.committed: {CadAssetStageState.quarantined},
    CadAssetStageState.rollingBack: {
      CadAssetStageState.rolledBack,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.rolledBack: {CadAssetStageState.quarantined},
    CadAssetStageState.quarantined: {},
  };

  Future<void> _update(
    Map<String, dynamic> next,
    CadAssetStageState target,
  ) async {
    if (!_transitions[state]!.contains(target)) {
      throw StateError('Illegal staging transition');
    }
    next['state'] = target.name;
    next['sequence'] = (_manifest!['sequence'] as int) + 1;
    next['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _writeManifest(next);
  }

  Future<void> _writeManifest(Map<String, dynamic> next) async {
    final current = File(path.join(stagingDirectory, 'manifest.json'));
    final previous = File(
      path.join(stagingDirectory, 'manifest.previous.json'),
    );
    final temporary = File(
      path.join(stagingDirectory, 'manifest.${_assetId('j1')}.tmp'),
    );
    final bytes = utf8.encode(
      jsonEncode({'data': next, 'checksum': _manifestChecksum(next)}),
    );
    if (bytes.length > 1024 * 1024) throw StateError('Manifest exceeds limit');
    await _paths.check(temporary.path);
    await temporary.create(exclusive: true);
    await temporary.writeAsBytes(bytes, flush: true);
    final reread = await _readAssetManifest(
      temporary,
      _paths,
      instanceId,
      operationId,
    );
    if (jsonEncode(reread) != jsonEncode(next)) {
      throw StateError('Journal temporary verification failed');
    }
    await _storage.checkpoint('manifest:${next['state']}:flushed');
    if (_manifest != null && !await _paths.exists(current.path)) {
      throw StateError('Current journal disappeared');
    }
    if (await _paths.exists(current.path)) {
      final valid = await _readAssetManifest(
        current,
        _paths,
        instanceId,
        operationId,
      );
      if (_manifest == null ||
          valid['sequence'] != _manifest!['sequence'] ||
          _manifestChecksum(valid) != _manifestChecksum(_manifest!)) {
        throw StateError('Manifest changed or last update was not confirmed');
      }
      final backup = File(
        path.join(stagingDirectory, 'previous.${_assetId('j1')}.tmp'),
      );
      await _paths.check(backup.path);
      await backup.create(exclusive: true);
      await backup.writeAsString(
        jsonEncode({'data': valid, 'checksum': _manifestChecksum(valid)}),
        flush: true,
      );
      await _readAssetManifest(backup, _paths, instanceId, operationId);
      await _paths.check(previous.path);
      await backup.rename(previous.path);
      await _readAssetManifest(previous, _paths, instanceId, operationId);
    }
    await _storage.checkpoint('manifest:${next['state']}:beforeReplace');
    await _paths.check(current.path);
    await _paths.check(temporary.path);
    await temporary.rename(current.path);
    final confirmed = await _readAssetManifest(
      current,
      _paths,
      instanceId,
      operationId,
    );
    if (_manifestChecksum(confirmed) != _manifestChecksum(next)) {
      throw StateError('Manifest readback mismatch');
    }
    _manifest = confirmed;
  }

  Future<void> _finish({required bool success}) {
    if (_finishing case final existing?) return existing;
    final done = Completer<void>();
    _finishing = done.future;
    unawaited(
      _finishWork(success).then(done.complete, onError: done.completeError),
    );
    return done.future;
  }

  Future<void> _finishWork(bool success) async {
    Object? cleanupError;
    // Promotion has released the project lock before native disposal waits.
    for (final owner in [..._shapes, ..._meshes]) {
      try {
        await owner.dispose();
      } catch (error) {
        cleanupError = error;
      }
    }
    if (_manifest == null) {
      if (cleanupError != null) throw cleanupError;
      return;
    }
    if (cleanupError != null || !success || _failure != null) {
      final next = _copy();
      (next['failures'] as List).add(
        cleanupError == null ? 'operationFailed' : 'nativeDisposeFailed',
      );
      next['quarantineReason'] = 'unconfirmedOperationOrNativeCleanup';
      await _update(next, CadAssetStageState.quarantined);
    } else if (state != CadAssetStageState.committed) {
      await _update(_copy(), CadAssetStageState.rollingBack);
      await _update(_copy(), CadAssetStageState.rolledBack);
    }
    if (cleanupError != null) throw cleanupError;
  }
}

final class CadAssetRecoveryResult {
  CadAssetRecoveryResult(
    this.directory,
    this.classification,
    this.usedBackup,
    this.assetsVerified,
  );
  final String directory, classification;
  final bool usedBackup, assetsVerified;
}

/// Read-only conservative recovery. Never races live staging by changing it.
Future<List<CadAssetRecoveryResult>> inspectCadAssetStaging(
  Directory project, {
  CadAssetStorage storage = const CadAssetStorage(),
}) async {
  final paths = await _AssetPaths.open(project);
  final staging = Directory(paths.location(['.cad-staging']));
  if (!await paths.exists(staging.path)) return [];
  final results = <CadAssetRecoveryResult>[];
  await for (final instance in staging.list(followLinks: false)) {
    if (instance is! Directory) continue;
    try {
      await paths.check(instance.path);
      _requireId(path.basename(instance.path), 'i1');
    } catch (_) {
      results.add(
        CadAssetRecoveryResult(
          instance.path,
          'quarantinedInvalidInstance',
          false,
          false,
        ),
      );
      continue;
    }
    await for (final operation in instance.list(followLinks: false)) {
      final i = path.basename(instance.path), o = path.basename(operation.path);
      var backup = false;
      try {
        await paths.check(operation.path);
        _requireId(o, 'o1');
        Map<String, dynamic> data;
        try {
          data = await _readAssetManifest(
            File(path.join(operation.path, 'manifest.json')),
            paths,
            i,
            o,
          );
        } catch (_) {
          backup = true;
          data = await _readAssetManifest(
            File(path.join(operation.path, 'manifest.previous.json')),
            paths,
            i,
            o,
          );
        }
        var complete = true;
        final assets = data['assets'] as List;
        for (final raw in assets) {
          final asset = raw as Map<String, dynamic>;
          final id = GeometryAssetId.fromJson(
            asset['reference'] as Map<String, dynamic>,
          );
          final destination = paths.location(['CAD', 'Assets', 'v1', id.value]);
          if (!await paths.exists(destination)) {
            complete = false;
            continue;
          }
          for (final entry
              in (asset['files'] as Map<String, dynamic>).entries) {
            final file = File(
              path.join(
                destination,
                CadAssetFile.values.byName(entry.key).relativePath,
              ),
            );
            await paths.check(file.path);
            final digest = await storage._digest(file),
                expected = entry.value as Map;
            if (digest['size'] != expected['size'] ||
                digest['sha256'] != expected['sha256']) {
              complete = false;
            }
          }
          final descriptor = File(path.join(destination, 'asset.json'));
          await paths.check(descriptor.path);
          final digest = await storage._digest(descriptor),
              expected = asset['descriptor'] as Map;
          if (digest['size'] != expected['size'] ||
              digest['sha256'] != expected['sha256']) {
            complete = false;
          }
        }
        final classification = backup
            ? 'quarantinedBackupOnly'
            : data['state'] == 'quarantined'
            ? 'quarantinedRecordedFailure'
            : complete && assets.isNotEmpty
            ? 'awaitingDocumentReconciliation'
            : [
                'commitIntent',
                'promoting',
                'committed',
                'quarantined',
              ].contains(data['state'])
            ? 'quarantinedAmbiguousPromotion'
            : data['state'] == 'rolledBack'
            ? 'rolledBackRetained'
            : 'preCommitRetained';
        results.add(
          CadAssetRecoveryResult(
            operation.path,
            classification,
            backup,
            complete && assets.isNotEmpty,
          ),
        );
      } catch (_) {
        results.add(
          CadAssetRecoveryResult(
            operation.path,
            'quarantinedInvalidManifestOrPath',
            backup,
            false,
          ),
        );
      }
    }
  }
  return results;
}
