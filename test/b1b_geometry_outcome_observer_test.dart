// B.1b.1 — observabilidade tipada no funil do OpenCascadeKernelAdapter.
//
// Prova que a observação é *passiva*: classifica execução nativa
// (`notVerified`) e falhas (`failure`), sem alterar resultado, exceção
// original, stack trace, custódia de tokens, métricas ou transações.
//
// Nenhum runtime OCCT é necessário: o bridge é um dublê determinístico e o
// caminho exercitado é o funil real (`create` -> KernelRuntime -> custódia).
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_bridge.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flcad_mobile/core/cad_kernel/validation/geometry_outcome.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  KernelTransaction transaction() => KernelTransaction(
    'tx-b1b1',
    'project',
    'opencascade',
    DateTime(2026, 1, 1),
    TransactionStatus.active,
    const [],
  );

  Future<ShapeHandle> createVertex(
    OpenCascadeKernelAdapter adapter, {
    Map<String, dynamic>? parameters,
    String persistentId = 'shape-b1b1',
  }) => adapter.create(
    'CREATE VERTEX',
    parameters ?? const {'x': 1.0, 'y': 2.0, 'z': 3.0},
    persistentId: persistentId,
    expectedType: CADShapeType.vertex,
    transaction: transaction(),
  );

  ShapeHandle referenceHandle() => ShapeHandle.reference(
    persistentId: 'shape-b1b1',
    kernelId: 'opencascade',
    type: CADShapeType.vertex,
  );

  group('sucesso nativo', () {
    test('emite exatamente um NotVerified e preserva o retorno', () async {
      final bridge = _ScriptedBridge();
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: bridge,
        onGeometryOutcome: emitted.add,
      );

      final handle = await createVertex(adapter);

      expect(emitted, hasLength(1));
      final outcome = emitted.single;
      expect(outcome.status, GeometryOutcomeStatus.notVerified);
      expect(outcome.execution, GeometryExecutionStatus.completed);
      expect(outcome.operation, 'occ-create-vertex');
      expect(outcome.operationClass, GeometryOperationClass.surfaceCreate);
      expect(outcome.shape?.persistentId, handle.persistentId);
      expect(outcome.shape?.handleFingerprint, handle.fingerprint);
      // Sem validação BREP não existe aprovação geométrica.
      expect(outcome.isValidatedSuccess, isFalse);
      expect(outcome.requiresVerification, isTrue);
      expect(outcome.errors, isEmpty);
      // O contrato carrega identidade, nunca o token nativo privado.
      expect(outcome.toJson().toString(), isNot(contains('native-CREATE')));

      // Retorno e custódia intactos.
      expect(handle.type, CADShapeType.vertex);
      expect(handle.revision, 1);
      expect(adapter.isUnmanaged(handle), isTrue);
      await adapter.destroy(handle);
      expect(bridge.destroyed, ['native-CREATE VERTEX']);
    });

    test('nunca classifica como SuccessChanged/SuccessUnchanged', () async {
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(),
        onGeometryOutcome: emitted.add,
      );

      await createVertex(adapter);

      expect(
        emitted.map((outcome) => outcome.status),
        everyElement(
          isNot(
            anyOf(
              GeometryOutcomeStatus.successChanged,
              GeometryOutcomeStatus.successUnchanged,
            ),
          ),
        ),
      );
      expect(
        emitted.single.isValidatedSuccess,
        isFalse,
        reason: 'nenhuma validação BREP foi executada nesta camada',
      );
    });
  });

  group('falhas classificadas', () {
    test('UnsupportedError -> Failure(unsupported)', () async {
      final thrown = UnsupportedError(
        'PATCH is not exported by OCCT native bridge',
      );
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(onCreate: () => _throwFromBridge(thrown)),
        onGeometryOutcome: emitted.add,
      );

      Object? caught;
      try {
        await createVertex(adapter);
        fail('create deveria propagar a falha nativa');
      } catch (error) {
        caught = error;
      }

      expect(identical(caught, thrown), isTrue);
      final outcome = emitted.single;
      expect(outcome.status, GeometryOutcomeStatus.failure);
      expect(outcome.execution, GeometryExecutionStatus.unsupported);
      expect(outcome.operationClass, GeometryOperationClass.surfaceCreate);
      expect(outcome.isValidatedSuccess, isFalse);
      expect(outcome.errors, isNotEmpty);
    });

    test('ArgumentError real (handle de outro kernel) -> invalidPrecondition',
        () async {
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(),
        onGeometryOutcome: emitted.add,
      );
      final foreign = ShapeHandle.reference(
        persistentId: 'foreign-1',
        kernelId: 'other-kernel',
        type: CADShapeType.face,
      );

      await expectLater(
        adapter.create(
          'EXTRUDE',
          {'inputs': foreign},
          persistentId: 'extrude-1',
          expectedType: CADShapeType.solid,
          transaction: transaction(),
        ),
        throwsArgumentError,
      );

      final outcome = emitted.single;
      expect(outcome.status, GeometryOutcomeStatus.failure);
      expect(outcome.execution, GeometryExecutionStatus.invalidPrecondition);
      expect(outcome.operation, 'occ-extrude');
      expect(outcome.operationClass, GeometryOperationClass.extrude);
    });

    test('StateError do bridge -> Failure(nativeFailure)', () async {
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(
          onCreate: () => _throwFromBridge(StateError('BRepAlgoAPI failed')),
        ),
        onGeometryOutcome: emitted.add,
      );

      await expectLater(createVertex(adapter), throwsStateError);

      final outcome = emitted.single;
      expect(outcome.execution, GeometryExecutionStatus.nativeFailure);
      expect(outcome.attributes['errorType'], 'StateError');
      expect(adapter.isUnmanaged(referenceHandle()), isFalse);
    });

    test('host nativo indisponível -> Failure(nativeFailure)', () async {
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: const UnavailableOpenCascadeBridge('occt host ausente'),
        onGeometryOutcome: emitted.add,
      );

      await expectLater(createVertex(adapter), throwsStateError);

      expect(emitted.single.status, GeometryOutcomeStatus.failure);
      expect(
        emitted.single.execution,
        GeometryExecutionStatus.nativeFailure,
      );
      expect(adapter.isUnmanaged(referenceHandle()), isFalse);
    });

    test('exceção não classificada -> Failure(unknownFailure)', () async {
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(
          onCreate: () => _throwFromBridge(const FormatException('payload')),
        ),
        onGeometryOutcome: emitted.add,
      );

      Object? caught;
      try {
        await createVertex(adapter);
        fail('create deveria propagar a falha');
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<FormatException>());
      final outcome = emitted.single;
      expect(outcome.execution, GeometryExecutionStatus.unknownFailure);
      expect(outcome.attributes['errorType'], 'FormatException');
      // Nunca rotulada automaticamente como falha nativa.
      expect(
        outcome.execution,
        isNot(GeometryExecutionStatus.nativeFailure),
      );
    });
  });

  group('preservação do caminho original', () {
    test('exceção original e stack trace sobrevivem ao observador', () async {
      final thrown = _ScriptError('bridge blew up');
      final emitted = <GeometryOutcome>[];
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(onCreate: () => _throwFromBridge(thrown)),
        onGeometryOutcome: emitted.add,
      );

      Object? caught;
      StackTrace? caughtStack;
      try {
        await createVertex(adapter);
        fail('create deveria propagar a falha');
      } catch (error, stackTrace) {
        caught = error;
        caughtStack = stackTrace;
      }

      expect(identical(caught, thrown), isTrue);
      expect(
        caughtStack.toString(),
        contains('_throwFromBridge'),
        reason: 'o stack trace deve continuar apontando o lançamento original',
      );
      expect(emitted.single.execution, GeometryExecutionStatus.unknownFailure);
    });

    test('observador que lança não altera o sucesso', () async {
      final bridge = _ScriptedBridge();
      final adapter = OpenCascadeKernelAdapter(
        bridge: bridge,
        onGeometryOutcome: (_) => throw StateError('consumidor quebrado'),
      );

      final handle = await createVertex(adapter);

      expect(handle.persistentId, 'shape-b1b1');
      expect(adapter.isUnmanaged(handle), isTrue);
    });

    test('observador que lança em falha não mascara a exceção original',
        () async {
      final thrown = ArgumentError('pré-condição inválida');
      final adapter = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(onCreate: () => _throwFromBridge(thrown)),
        onGeometryOutcome: (_) => throw StateError('consumidor quebrado'),
      );

      Object? caught;
      try {
        await createVertex(adapter);
        fail('create deveria propagar a falha original');
      } catch (error) {
        caught = error;
      }

      expect(identical(caught, thrown), isTrue);
    });

    test('sem observador o caminho e o custo anteriores são preservados',
        () async {
      final bridge = _ScriptedBridge();
      final adapter = OpenCascadeKernelAdapter(bridge: bridge);

      final handle = await createVertex(adapter);

      expect(handle.persistentId, 'shape-b1b1');
      expect(handle.type, CADShapeType.vertex);
      expect(bridge.initializeCalled, isTrue);
      expect(adapter.runtime.analytics.operations, 1);
      await adapter.destroy(handle);
      expect(bridge.destroyed, ['native-CREATE VERTEX']);
    });

    test('métrica de runtime continua registrada em sucesso e em falha',
        () async {
      final healthy = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(),
        onGeometryOutcome: (_) {},
      );
      await createVertex(healthy);
      expect(healthy.runtime.analytics.operations, 1);

      final failing = OpenCascadeKernelAdapter(
        bridge: _ScriptedBridge(
          onCreate: () => _throwFromBridge(StateError('falha nativa')),
        ),
        onGeometryOutcome: (_) {},
      );
      await expectLater(createVertex(failing), throwsStateError);
      expect(failing.runtime.analytics.operations, 1);
    });

    test('nenhuma publicação nova: token só existe quando a criação conclui',
        () async {
      final bridge = _ScriptedBridge();
      final adapter = OpenCascadeKernelAdapter(
        bridge: bridge,
        onGeometryOutcome: (_) {},
      );
      final foreign = ShapeHandle.reference(
        persistentId: 'foreign-2',
        kernelId: 'other-kernel',
        type: CADShapeType.face,
      );

      await expectLater(
        adapter.create(
          'EXTRUDE',
          {'inputs': foreign},
          persistentId: 'extrude-1',
          expectedType: CADShapeType.solid,
          transaction: transaction(),
        ),
        throwsArgumentError,
      );
      expect(
        adapter.isUnmanaged(
          ShapeHandle.reference(
            persistentId: 'extrude-1',
            kernelId: 'opencascade',
            type: CADShapeType.solid,
          ),
        ),
        isFalse,
      );
      expect(bridge.created, isEmpty);
    });
  });

  group('classificação de tokens nativos', () {
    test('fromNativeToken mapeia o funil real sem inventar classe', () {
      const expected = <String, GeometryOperationClass>{
        'occ-extrude': GeometryOperationClass.extrude,
        'occ-extrude-multi': GeometryOperationClass.extrude,
        'occ-revolve': GeometryOperationClass.revolve,
        'occ-boolean-cut': GeometryOperationClass.booleanOp,
        'occ-fuse': GeometryOperationClass.booleanOp,
        'occ-fillet': GeometryOperationClass.fillet,
        'occ-remove-fillet': GeometryOperationClass.removeFillet,
        'occ-chamfer': GeometryOperationClass.chamfer,
        'occ-heal': GeometryOperationClass.heal,
        'occ-healing-proposals': GeometryOperationClass.heal,
        'occ-merge-faces': GeometryOperationClass.heal,
        'occ-loft': GeometryOperationClass.loft,
        'occ-sweep': GeometryOperationClass.sweep,
        'occ-import-step': GeometryOperationClass.importShape,
        'occ-import-stl': GeometryOperationClass.importShape,
        'occ-export-brep': GeometryOperationClass.exportShape,
        'occ-meshing': GeometryOperationClass.mesh,
        'occ-create-vertex': GeometryOperationClass.surfaceCreate,
        'occ-create-solid': GeometryOperationClass.surfaceCreate,
        'occ-create-planar-face': GeometryOperationClass.surfaceCreate,
        'occ-generate-sphere': GeometryOperationClass.surfaceCreate,
        'occ-generate-torus': GeometryOperationClass.surfaceCreate,
        'occ-replace-face': GeometryOperationClass.surfaceEdit,
        'occ-delete-face': GeometryOperationClass.surfaceEdit,
        'occ-sewing': GeometryOperationClass.surfaceEdit,
        'occ-sew': GeometryOperationClass.surfaceEdit,
        'occ-unsew-face': GeometryOperationClass.surfaceEdit,
        'occ-boundary-extend': GeometryOperationClass.surfaceEdit,
        'occ-boundary-trim': GeometryOperationClass.surfaceEdit,
        'occ-offset-walls': GeometryOperationClass.surfaceEdit,
        'occ-transform-shape': GeometryOperationClass.surfaceEdit,
        'occ-reverse-normal': GeometryOperationClass.surfaceEdit,
        'occ-morph': GeometryOperationClass.surfaceEdit,
        'occ-nurbs': GeometryOperationClass.surfaceEdit,
        'occ-fill': GeometryOperationClass.surfaceEdit,
        'occ-validate': GeometryOperationClass.unknown,
        '': GeometryOperationClass.unknown,
        'occ-': GeometryOperationClass.unknown,
      };

      for (final entry in expected.entries) {
        expect(
          GeometryOperationClass.fromNativeToken(entry.key),
          entry.value,
          reason: 'token ${entry.key}',
        );
      }
    });
  });
}

/// Exceção arbitrária do dublê: não é nativa, não é de entrada.
class _ScriptError implements Exception {
  const _ScriptError(this.message);
  final String message;
  @override
  String toString() => '_ScriptError: $message';
}

/// Lança a partir de um frame nomeado, para provar preservação de stack trace.
Future<OpenCascadeNativeShape> _throwFromBridge(Object error) {
  throw error;
}

/// Dublê determinístico do host nativo: só o funil de criação é roteirizado.
class _ScriptedBridge extends UnavailableOpenCascadeBridge {
  _ScriptedBridge({this.onCreate}) : super('scripted bridge');

  final Future<OpenCascadeNativeShape> Function()? onCreate;
  bool initializeCalled = false;
  final List<String> created = [];
  final List<String> destroyed = [];

  @override
  Future<void> initialize() async => initializeCalled = true;

  @override
  Future<String> version() async => '0.0.0-scripted';

  @override
  Future<Set<String>> capabilities() async => {'STEP', 'surface'};

  @override
  Future<Map<String, dynamic>> diagnostics() async => {'healthy': true};

  @override
  Future<OpenCascadeNativeShape> createShape(
    String operation,
    Map<String, dynamic> parameters,
    CADShapeType expectedType,
  ) {
    final script = onCreate;
    if (script != null) return script();
    created.add(operation);
    return Future.value(
      OpenCascadeNativeShape(
        token: 'native-$operation',
        type: expectedType,
        fingerprint: 'fp:$operation',
        metadata: {'operator': operation},
      ),
    );
  }

  @override
  Future<void> destroyShape(String nativeToken) async =>
      destroyed.add(nativeToken);
}
