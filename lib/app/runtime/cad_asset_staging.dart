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
  CadAssetOperationFailure(
    this.cause,
    this.cleanup,
    this.causeStack,
    this.cleanupStack,
  );
  final Object cause, cleanup;
  final StackTrace causeStack, cleanupStack;
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
      result = await _withGeometryStagingTransaction(
        tx,
        action,
        cancellation: cancellation,
        lockTimeout: lockTimeout,
      );
    });
    return result;
  }
}

/// Runtime-only composition for a producer already admitted by [_enqueue].
Future<T> _withGeometryStagingTransaction<T>(
  _CadTransaction tx,
  Future<T> Function(CadGeometryStagingOperation) action, {
  CadAssetCancellation? cancellation,
  Duration lockTimeout = const Duration(seconds: 10),
}) async {
  tx.validate();
  if (tx.directory == null || tx.document == null) {
    throw StateError('No active project');
  }
  final paths = await _AssetPaths.open(tx.directory!);
  try {
    tx.validate();
    final operation = CadGeometryStagingOperation._(
      tx,
      paths,
      tx.owner._assetInstance,
      _assetId('o1'),
      tx.owner._assetStorage,
      cancellation ?? CadAssetCancellation(),
      lockTimeout,
    );
    T? result;
    var hasResult = false;
    try {
      await operation._start();
      result = await action(operation);
      hasResult = true;
      operation._accepting = false;
      await operation._tail;
      if (tx.committed) {
        if (operation.state != CadAssetStageState.committed) {
          throw StateError('Document committed before asset promotion');
        }
      } else {
        operation._validate();
      }
    } catch (error, stack) {
      operation._abort(error, stack);
      try {
        await tx.owner._assetStorage.checkpoint('operation:drainingAfterAbort');
      } catch (error, stack) {
        operation._abort(error, stack);
      }
      await operation._tail;
    }
    operation._revoke();
    try {
      await operation._finish(success: operation._failure == null);
    } catch (cleanup, stack) {
      if (operation._failure case final cause?
          when !identical(cause, cleanup)) {
        Error.throwWithStackTrace(
          CadAssetOperationFailure(
            cause,
            cleanup,
            operation._failureStack!,
            stack,
          ),
          operation._failureStack!,
        );
      }
      Error.throwWithStackTrace(cleanup, stack);
    }
    if (operation._failure case final cause?) {
      Error.throwWithStackTrace(cause, operation._failureStack!);
    }
    if (!hasResult) throw StateError('Staging completed without a result');
    return result as T;
  } finally {
    paths.dispose();
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
  final _sealedNativeAssets = <NativeSealedStagedAsset>{};
  bool _active = true, _accepting = true;
  Future<void> _tail = Future.value();
  Future<void>? _finishing;
  Object? _failure;
  StackTrace? _failureStack;
  Object? _resourceCleanupError;
  StackTrace? _resourceCleanupStack;
  final _revoked = Completer<void>();
  final _completedMoves = <String>[];
  late final _interrupted = Future.any<void>([
    _revoked.future,
    _cancellation._done.future,
    _tx.revocation.future,
    _tx.owner._assetShutdown.future,
  ]);
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

  void _revoke() {
    _accepting = false;
    _active = false;
    if (!_revoked.isCompleted) _revoked.complete();
  }

  void _abort(Object error, StackTrace stack) {
    _revoke(); // Synchronous: admitted work loses authority before draining.
    _failure ??= error;
    _failureStack ??= stack;
  }

  Future<void> _closeResource(Future<void> Function() close) async {
    try {
      await close();
    } catch (error, stack) {
      final previous = _resourceCleanupError;
      _resourceCleanupError = previous == null
          ? error
          : CadAssetOperationFailure(
              previous,
              error,
              _resourceCleanupStack!,
              stack,
            );
      _resourceCleanupStack ??= stack;
      rethrow;
    }
  }

  // One interruption listener per stream, rather than one retained listener per
  // chunk. Cancel the subscription before closing its destination handle.
  Stream<List<int>> _cancellable(Stream<List<int>> source) async* {
    final iterator = StreamIterator(source);
    Completer<bool>? pending;
    unawaited(
      _interrupted.then((_) {
        final wait = pending;
        if (wait != null && !wait.isCompleted) wait.complete(false);
      }),
    );
    try {
      while (true) {
        _validate();
        final wait = pending = Completer<bool>();
        unawaited(
          iterator.moveNext().then(
            (value) {
              if (!wait.isCompleted) wait.complete(value);
            },
            onError: (Object error, StackTrace stack) {
              if (!wait.isCompleted) wait.completeError(error, stack);
            },
          ),
        );
        final hasNext = await wait.future;
        pending = null;
        _validate();
        if (!hasNext) break;
        yield iterator.current;
      }
    } catch (error, stack) {
      _abort(error, stack);
      rethrow;
    } finally {
      pending = null;
      await _closeResource(iterator.cancel);
    }
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
      } catch (error, stack) {
        _abort(error, stack);
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
    await _paths.directories(
      path.join(stagingDirectory, 'files'),
      authorize: _validate,
    );
    _validate();
    final now = DateTime.now().toUtc().toIso8601String();
    await _writeManifest({
      'schema': 'flcad.geometry-staging',
      'version': 1,
      'instance': instanceId,
      'operation': operationId,
      'project': _tx.document!.projectId,
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
    final value = _storage.newAssetId();
    _requireId(value, 'ga1');
    final asset = GeometryAssetId._(value);
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
    await _paths.directories(_assetDirectory(asset), authorize: _validate);
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
    final target = _paths.file(
      path.join(_assetDirectory(asset), kind.relativePath),
    );
    await _paths.directories(target.parent.path, authorize: _validate);
    await _paths.check(target.path);
    _validate();
    await target.create(exclusive: true);
    _validate();
    final file = await target.open(mode: FileMode.writeOnly);
    Map<String, dynamic>? sealed;
    try {
      await for (final chunk in _cancellable(bytes)) {
        _validate();
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          _validate();
          await file.writeFrom(
            chunk,
            offset,
            math.min(offset + 65536, chunk.length),
          );
          await _storage.checkpoint('file:chunkWritten');
        }
      }
      _validate();
      await file.flush();
      sealed = await _paths.digest(target.path);
    } catch (error, stack) {
      _abort(error, stack);
      rethrow;
    } finally {
      await _closeResource(file.close);
    }
    await _storage.checkpoint('file:flushed');
    _validate();
    await _paths.check(target.path);
    final digest = await _paths.digest(target.path);
    if (!_sameAssetIdentity(digest, sealed)) {
      throw StateError('Payload identity changed after seal');
    }
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

  /// 2B2A2-only native payload path. OCCT writes directly to a CAF writer
  /// lease; Dart receives only the sealed metadata. This deliberately lives on
  /// the transaction-scoped staging operation rather than on a public export
  /// API.
  /// Produces a sealed, operation-owned capability. Its CAF object ID remains
  /// private; callers can only consume the same object through a source lease
  /// and must release it before the existing directory promotion.
  Future<NativeSealedStagedAsset> writeNativeShape(
    GeometryAssetId asset,
    CadAssetFile kind,
    OpenCascadeKernelAdapter kernel,
    OwnedNativeShape owner,
  ) => _run(() async {
    _preparing();
    if (kind != CadAssetFile.brep && kind != CadAssetFile.display) {
      throw ArgumentError.value(kind, 'kind', 'Native shape payload required');
    }
    final next = _copy();
    final files = _asset(next, asset)['files'] as Map<String, dynamic>;
    if (files.containsKey(kind.name)) {
      throw StateError('Asset file already acquired');
    }
    files[kind.name] = {'status': 'writing', 'allowEmpty': false};
    await _update(next, CadAssetStageState.preparing);
    final target = _paths.file(
      path.join(_assetDirectory(asset), kind.relativePath),
    );
    await _paths.directories(target.parent.path, authorize: _validate);
    await _paths.check(target.path);
    _validate();
    await target.create(exclusive: true);
    final lease = owner.borrow();
    Map<String, dynamic>? sealed;
    NativeSealedStagedAsset? retained;
    try {
      _validate();
      sealed = await kernel.streamShapeIntoStaging(
        filesystem: _paths.native,
        file: _paths.openFile(target.path),
        shape: lease,
        displayStl: kind == CadAssetFile.display,
      );
      _validate();
      if (sealed['size'] == 0) {
        throw StateError('Empty native geometry payload');
      }
      retained = NativeSealedStagedAsset._(this, target.path, {...sealed});
      _sealedNativeAssets.add(retained);
    } catch (error, stack) {
      _abort(error, stack);
      rethrow;
    } finally {
      lease.release();
      if (retained == null) _paths.release(target.path);
    }
    final fileMetadata = Map<String, dynamic>.of(sealed)..remove('state');
    final complete = _copy();
    (_asset(complete, asset)['files'] as Map)[kind.name] = {
      ...fileMetadata,
      'status': 'written',
      'allowEmpty': false,
    };
    await _update(complete, CadAssetStageState.preparing);
    return retained;
  });

  /// Runtime-only managed producer. The shape owner remains private and only a
  /// borrowed custody lease reaches the C-to-C writer bridge.
  Future<NativeSealedStagedAsset> _writeManagedShape(
    GeometryAssetId asset,
    CadAssetFile kind,
    OpenCascadeKernelAdapter kernel,
    ManagedNativeShape shape, {
    String? bridgePath,
  }) => _run(() async {
    _preparing();
    if (kind != CadAssetFile.brep && kind != CadAssetFile.display) {
      throw ArgumentError.value(kind, 'kind', 'Native shape payload required');
    }
    final next = _copy();
    final files = _asset(next, asset)['files'] as Map<String, dynamic>;
    if (files.containsKey(kind.name)) {
      throw StateError('Asset file already acquired');
    }
    files[kind.name] = {'status': 'writing', 'allowEmpty': false};
    await _update(next, CadAssetStageState.preparing);
    final target = _paths.file(
      path.join(_assetDirectory(asset), kind.relativePath),
    );
    await _paths.directories(target.parent.path, authorize: _validate);
    await _paths.check(target.path);
    _validate();
    await target.create(exclusive: true);
    Map<String, dynamic>? sealed;
    NativeSealedStagedAsset? retained;
    try {
      _validate();
      final produced = await shape.withLease(
        (lease) => kernel.streamShapeIntoStaging(
          filesystem: _paths.native,
          file: _paths.openFile(target.path),
          shape: lease,
          displayStl: kind == CadAssetFile.display,
          bridgePath: bridgePath,
        ),
      );
      sealed = produced;
      _validate();
      if (produced['size'] == 0) {
        throw StateError('Empty native geometry payload');
      }
      retained = NativeSealedStagedAsset._(this, target.path, {...produced});
      _sealedNativeAssets.add(retained);
    } catch (error, stack) {
      _abort(error, stack);
      rethrow;
    } finally {
      if (retained == null) _paths.release(target.path);
    }
    final fileMetadata = Map<String, dynamic>.of(sealed)..remove('state');
    final complete = _copy();
    (_asset(complete, asset)['files'] as Map)[kind.name] = {
      ...fileMetadata,
      'status': 'written',
      'allowEmpty': false,
    };
    await _update(complete, CadAssetStageState.preparing);
    return retained;
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
      final descriptor = _paths.file(
        path.join(_assetDirectory(asset), 'asset.json'),
      );
      await _paths.check(descriptor.path);
      _validate();
      await descriptor.create(exclusive: true);
      _validate();
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
      record['descriptor'] = await _paths.digest(descriptor.path);
      _paths.release(descriptor.path);
    }
    await _update(next, CadAssetStageState.prepared);
  });

  Future<PreparedGeometryAssets> promote() => _run(() async {
    if (state != CadAssetStageState.prepared) {
      throw StateError('Only prepared staging may commit');
    }
    if (_sealedNativeAssets.any((asset) => !asset.isReleased)) {
      throw StateError('Sealed native capability must close before promotion');
    }
    return _ProjectAssetLocks.run(
      _paths,
      instanceId,
      operationId,
      _lockTimeout,
      _interrupted,
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
          await _paths.directories(
            path.dirname(destination),
            authorize: _validate,
          );
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
          await _storage.checkpoint('promotion:renameReady');
          _validate();
          _paths.rename(source, destination);
          // The synchronous OS rename succeeded. Record that fact before any
          // await, even if revocation prevents the subsequent journal advance.
          _completedMoves.add(asset.value);
          await _storage.checkpoint('promotion:renamed');
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
      final file = _paths.file(path.join(directory, kind.relativePath));
      expected.add(path.normalize(file.path));
      await _paths.check(file.path);
      final digest = await _paths.digest(file.path);
      if (!_sameAssetIdentity(digest, info)) {
        throw StateError('Payload changed after validation');
      }
    }
    if (descriptor) {
      final file = _paths.file(path.join(directory, 'asset.json'));
      expected.add(path.normalize(file.path));
      await _paths.check(file.path);
      final digest = await _paths.digest(file.path),
          info = record['descriptor'] as Map;
      if (!_sameAssetIdentity(digest, info)) {
        throw StateError('Asset descriptor changed');
      }
    }
    await for (final entry in _paths.list(directory, recursive: true)) {
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
    CadAssetStageState.committed: {
      CadAssetStageState.committed,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.rollingBack: {
      CadAssetStageState.rolledBack,
      CadAssetStageState.quarantined,
    },
    CadAssetStageState.rolledBack: {CadAssetStageState.quarantined},
    CadAssetStageState.quarantined: {},
  };

  Future<void> _update(
    Map<String, dynamic> next,
    CadAssetStageState target, {
    bool cleanup = false,
    bool documentConfirmation = false,
  }) async {
    if (!_transitions[state]!.contains(target)) {
      throw StateError('Illegal staging transition');
    }
    next['state'] = target.name;
    next['sequence'] = (_manifest!['sequence'] as int) + 1;
    next['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _writeManifest(
      next,
      cleanup: cleanup,
      documentConfirmation: documentConfirmation,
    );
  }

  Future<void> _confirmDocumentPublished() async {
    if (!_tx.committed ||
        state != CadAssetStageState.committed ||
        _failure != null ||
        !_active ||
        !_accepting) {
      throw StateError('Document publication cannot be confirmed');
    }
    final next = _copy()..['documentPublished'] = true;
    await _update(
      next,
      CadAssetStageState.committed,
      documentConfirmation: true,
    );
  }

  Future<void> _writeManifest(
    Map<String, dynamic> next, {
    bool cleanup = false,
    bool documentConfirmation = false,
  }) async {
    void authorize() {
      if (documentConfirmation) {
        if (cleanup ||
            !_tx.committed ||
            state != CadAssetStageState.committed ||
            next['state'] != CadAssetStageState.committed.name ||
            next['documentPublished'] != true ||
            !_active ||
            !_accepting) {
          throw StateError('Invalid documentary confirmation authority');
        }
      } else if (!cleanup) {
        _validate();
      } else if (_finishing == null ||
          _active ||
          _accepting ||
          ![
            'quarantined',
            'rollingBack',
            'rolledBack',
          ].contains(next['state'])) {
        throw StateError('Invalid internal cleanup authority');
      }
    }

    authorize();
    final current = _paths.file(path.join(stagingDirectory, 'manifest.json'));
    final previous = _paths.file(
      path.join(stagingDirectory, 'manifest.previous.json'),
    );
    final temporary = _paths.file(
      path.join(stagingDirectory, 'manifest.${_assetId('j1')}.tmp'),
    );
    final bytes = utf8.encode(
      jsonEncode({'data': next, 'checksum': _manifestChecksum(next)}),
    );
    if (bytes.length > 1024 * 1024) throw StateError('Manifest exceeds limit');
    await _paths.check(temporary.path);
    authorize();
    await temporary.create(exclusive: true);
    authorize();
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
      final backup = _paths.file(
        path.join(stagingDirectory, 'previous.${_assetId('j1')}.tmp'),
      );
      await _paths.check(backup.path);
      authorize();
      await backup.create(exclusive: true);
      authorize();
      await backup.writeAsString(
        jsonEncode({'data': valid, 'checksum': _manifestChecksum(valid)}),
        flush: true,
      );
      await _readAssetManifest(backup, _paths, instanceId, operationId);
      await _paths.check(previous.path);
      authorize();
      final previousExists = await _paths.exists(previous.path);
      authorize();
      if (previousExists) _paths.retire(previous.path);
      authorize();
      await backup.rename(previous.path);
      await _readAssetManifest(previous, _paths, instanceId, operationId);
    }
    await _storage.checkpoint('manifest:${next['state']}:beforeReplace');
    await _paths.check(current.path);
    await _paths.check(temporary.path);
    authorize();
    final currentExists = await _paths.exists(current.path);
    authorize();
    if (currentExists) _paths.retire(current.path);
    authorize();
    await temporary.rename(current.path);
    await _storage.checkpoint('manifest:${next['state']}:replaced');
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
    Object? cleanupError = _resourceCleanupError;
    StackTrace? cleanupStack = _resourceCleanupStack;
    void recordCleanup(Object error, StackTrace stack) {
      final previous = cleanupError;
      cleanupError = previous == null
          ? error
          : CadAssetOperationFailure(previous, error, cleanupStack!, stack);
      cleanupStack ??= stack;
    }

    try {
      await _storage.checkpoint('cleanup:started');
    } catch (error, stack) {
      recordCleanup(error, stack);
    }
    // Promotion has released the project lock before native disposal waits.
    for (final asset in _sealedNativeAssets.toList()) {
      try {
        await asset._releaseAfterDrain();
      } catch (error, stack) {
        recordCleanup(error, stack);
      }
    }
    for (final owner in [..._shapes, ..._meshes]) {
      try {
        await owner.dispose();
      } catch (error, stack) {
        recordCleanup(error, stack);
      }
    }
    if (_manifest == null) {
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError!, cleanupStack!);
      }
      return;
    }
    try {
      if (cleanupError != null || !success || _failure != null) {
        final next = _copy();
        next['promoted'] = {
          ...next['promoted'] as List,
          ..._completedMoves,
        }.toList();
        (next['failures'] as List).add(
          cleanupError == null ? 'operationFailed' : 'cleanupFailed',
        );
        next['quarantineReason'] = 'unconfirmedOperationOrNativeCleanup';
        await _update(next, CadAssetStageState.quarantined, cleanup: true);
      } else if (state != CadAssetStageState.committed) {
        await _update(_copy(), CadAssetStageState.rollingBack, cleanup: true);
        await _update(_copy(), CadAssetStageState.rolledBack, cleanup: true);
      }
    } catch (error, stack) {
      recordCleanup(error, stack);
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStack!);
    }
  }
}

/// A sealed CAF payload retained exclusively by its staging operation.
///
/// The native capability is deliberately private. [metadata] is the immutable
/// identity recorded by the operation: size, SHA-256, volume and file ID. The
/// capability survives only until the C-to-C source call returns and custody
/// has captured the imported resource; directory promotion then reopens by
/// anchored relative components and compares against this same metadata.
final class NativeSealedStagedAsset {
  NativeSealedStagedAsset._(
    this._operation,
    this._path,
    Map<String, dynamic> sealed,
  ) : metadata = Map.unmodifiable(sealed);

  final CadGeometryStagingOperation _operation;
  final String _path;
  final Map<String, dynamic> metadata;
  bool _released = false;
  bool _sourceLeaseActive = false;

  bool get isReleased => _released;

  void _ensureLive() {
    if (_released) throw StateError('Sealed staged capability is released');
  }

  /// Reads exactly the sealed CAF object through the native source bridge.
  /// This method never supplies a pathname and no payload bytes enter Dart.
  Future<NativeSourceResource> readAs(
    OpenCascadeKernelAdapter kernel, {
    required NativeResourceKind kind,
    required NativeSourceCancellation cancellation,
    String? bridgePath,
  }) => _operation._run(() async {
    _operation._validate();
    _ensureLive();
    if (_sourceLeaseActive) throw StateError('Source lease already active');
    _sourceLeaseActive = true;
    NativeSourceResource? captured;
    try {
      captured = await kernel.readOwnedAsset(
        filesystem: _operation._paths.native,
        file: _operation._paths.openFile(_path),
        expected: metadata,
        kind: kind,
        cancellation: cancellation,
        bridgePath: bridgePath,
      );
      _operation._validate();
      return captured;
    } on NativeSourcePublicationFailure catch (error, stack) {
      try {
        await error.resource.dispose();
      } catch (cleanup, cleanupStack) {
        Error.throwWithStackTrace(
          CadAssetOperationFailure(error.failure, cleanup, stack, cleanupStack),
          stack,
        );
      }
      Error.throwWithStackTrace(error.failure, stack);
    } catch (error, stack) {
      if (captured != null) {
        try {
          await captured.dispose();
        } catch (cleanup, cleanupStack) {
          Error.throwWithStackTrace(
            CadAssetOperationFailure(error, cleanup, stack, cleanupStack),
            stack,
          );
        }
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _sourceLeaseActive = false;
    }
  });

  /// Idempotent. A release requested during source consumption waits for the
  /// admitted operation tail, then closes only this operation's capability.
  /// It never deletes or otherwise mutates the retained staging evidence.
  Future<void> release() async {
    if (_released) return;
    await _operation._tail;
    await _releaseAfterDrain();
  }

  Future<void> _releaseAfterDrain() async {
    if (_released) return;
    if (_sourceLeaseActive) {
      throw StateError('Cannot close sealed capability during source lease');
    }
    _released = true;
    _operation._paths.release(_path);
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
  try {
    final staging = Directory(paths.location(['.cad-staging']));
    if (!await paths.exists(staging.path)) return [];
    final results = <CadAssetRecoveryResult>[];
    await for (final instance in paths.list(staging.path)) {
      if (instance is! Directory && instance is! Link) continue;
      try {
        if (instance is Link) throw StateError('Reparse in recovery');
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
      List<FileSystemEntity> operations;
      try {
        operations = await paths.list(instance.path).toList();
      } on CadAssetNativeError {
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
      for (final operation in operations) {
        final i = path.basename(instance.path),
            o = path.basename(operation.path);
        var backup = false;
        try {
          if (operation is! Directory) {
            throw StateError('Invalid recovery entry');
          }
          await paths.check(operation.path);
          _requireId(o, 'o1');
          Map<String, dynamic> data;
          try {
            data = await _readAssetManifest(
              paths.file(path.join(operation.path, 'manifest.json')),
              paths,
              i,
              o,
            );
          } catch (_) {
            backup = true;
            data = await _readAssetManifest(
              paths.file(path.join(operation.path, 'manifest.previous.json')),
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
            final destination = paths.location([
              'CAD',
              'Assets',
              'v1',
              id.value,
            ]);
            if (!await paths.exists(destination)) {
              complete = false;
              continue;
            }
            for (final entry
                in (asset['files'] as Map<String, dynamic>).entries) {
              final file = paths.file(
                path.join(
                  destination,
                  CadAssetFile.values.byName(entry.key).relativePath,
                ),
              );
              await paths.check(file.path);
              final digest = await paths.digest(file.path),
                  expected = entry.value as Map;
              if (!_sameAssetIdentity(digest, expected)) {
                complete = false;
              }
            }
            final descriptor = paths.file(path.join(destination, 'asset.json'));
            await paths.check(descriptor.path);
            final digest = await paths.digest(descriptor.path),
                expected = asset['descriptor'] as Map;
            if (!_sameAssetIdentity(digest, expected)) {
              complete = false;
            }
          }
          final classification = backup
              ? 'quarantinedBackupOnly'
              : data['state'] == 'quarantined'
              ? 'quarantinedRecordedFailure'
              : data['documentPublished'] == true && complete
              ? 'documentPublished'
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
  } finally {
    paths.dispose();
  }
}

bool _sameAssetIdentity(Map actual, Map expected) => [
  'size',
  'sha256',
  'volume',
  'fileId',
].every((key) => actual[key] == expected[key] && actual[key] != null);
