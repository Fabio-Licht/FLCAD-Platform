import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../core/cad_document/cad_document.dart';
import '../../core/cad_kernel/io/kernel_io_models.dart';
import '../../core/cad_kernel/manager/kernel_manager.dart';
import '../../core/import_export/import_export.dart';
import '../../features/projects/data/project_repository.dart';
import '../../features/projects/domain/project_manager.dart';
import '../runtime/cad_runtime.dart';

typedef ManagedStepFilePicker =
    Future<String?> Function(List<String> allowedExtensions);

typedef ManagedStepProjectOpener =
    Future<void> Function(String projectId, CadAssetCancellation cancellation);

typedef ManagedStepImporter =
    Future<CadDocumentEntity> Function(
      String locator,
      CadAssetCancellation cancellation,
    );

class DesktopCadController extends ChangeNotifier {
  DesktopCadController({
    required this.kernels,
    required this.projects,
    ProjectRepository? projectRepository,
    ImportExportRepository? importExportRepository,
    ManagedStepFilePicker? managedStepFilePicker,
    ManagedStepProjectOpener? managedStepProjectOpener,
    ManagedStepImporter? managedStepImporter,
  }) : projectRepository = projectRepository ?? ProjectRepository(),
       importExportRepository =
           importExportRepository ?? const ImportExportRepository(),
       _managedStepFilePicker = managedStepFilePicker ?? _pickManagedStepFile {
    runtime = CadRuntime(kernels: kernels);
    _managedStepProjectOpener =
        managedStepProjectOpener ?? _openManagedStepProject;
    _managedStepImporter = managedStepImporter ?? _importManagedStep;
  }
  final KernelManager kernels;
  final ProjectManager projects;
  final ProjectRepository projectRepository;
  final ImportExportRepository importExportRepository;
  final ManagedStepFilePicker _managedStepFilePicker;
  late final ManagedStepProjectOpener _managedStepProjectOpener;
  late final ManagedStepImporter _managedStepImporter;
  late final CadRuntime runtime;
  ImportedCadDocument? get document => runtime.activeImport;
  KernelMeshGeometry? get meshGeometry => runtime.activeMeshGeometry;
  String? message;
  bool busy = false;
  double progress = 0;
  bool _selectingManagedStep = false;
  CadAssetCancellation? _managedStepCancellation;

  bool get managedStepOperationActive =>
      _selectingManagedStep || _managedStepCancellation != null;
  bool get isBusy => busy || managedStepOperationActive;
  bool get supportsManagedStep => Platform.isWindows;
  bool get canImportManagedStep =>
      supportsManagedStep && projects.current != null && !isBusy;
  bool get canCancelManagedStepImport => _managedStepCancellation != null;

  void setStatus(String value) {
    message = value;
    notifyListeners();
  }

  /// The selected locator is deliberately passed straight to the runtime.
  /// The UI never opens, reads, hashes, or persists the selected file.
  Future<void> pickAndImportManagedStep() async {
    if (!canImportManagedStep) {
      if (projects.current == null) {
        setStatus('Abra ou crie um projeto antes de importar STEP.');
      }
      return;
    }
    _selectingManagedStep = true;
    message = 'Selecione uma peça STEP para importar.';
    notifyListeners();
    String? locator;
    try {
      locator = await _managedStepFilePicker(const ['step', 'stp']);
    } finally {
      _selectingManagedStep = false;
    }
    if (locator == null) {
      message = null;
      notifyListeners();
      return;
    }

    final project = projects.current;
    if (project == null) {
      setStatus('Abra ou crie um projeto antes de importar STEP.');
      return;
    }
    final cancellation = CadAssetCancellation();
    _managedStepCancellation = cancellation;
    message = 'Importando peça STEP...';
    notifyListeners();
    try {
      await _managedStepProjectOpener(project.id, cancellation);
      final entity = await _managedStepImporter(locator, cancellation);
      if (cancellation.isCancelled) return;
      runtime.select({entity.id});
      final name = entity.data['name'];
      final unit = entity.data['declaredUnit'];
      final suffix = unit is String && unit.isNotEmpty ? ' ($unit)' : '';
      message = name is String && name.isNotEmpty
          ? 'Peça STEP "$name"$suffix importada.'
          : 'Peça STEP$suffix importada.';
    } catch (error) {
      message = cancellation.isCancelled
          ? 'Importação STEP cancelada.'
          : runtime.recoveryRequired
          ? 'A importação STEP foi confirmada e requer recuperação antes de continuar.'
          : _managedStepFriendlyError(error);
    } finally {
      _managedStepCancellation = null;
      notifyListeners();
    }
  }

  void cancelManagedStepImport() {
    final cancellation = _managedStepCancellation;
    if (cancellation == null) return;
    cancellation.cancel();
    message = 'Cancelando importação STEP...';
    notifyListeners();
  }

  Future<void> _openManagedStepProject(
    String projectId,
    CadAssetCancellation cancellation,
  ) async {
    if (runtime.document?.projectId == projectId) return;
    final directory = await projectRepository.directoryFor(projectId);
    await runtime.open(projectId, directory, cancellation: cancellation);
  }

  Future<CadDocumentEntity> _importManagedStep(
    String locator,
    CadAssetCancellation cancellation,
  ) => runtime.importManagedStep(locator, cancellation: cancellation);

  static Future<String?> _pickManagedStepFile(
    List<String> allowedExtensions,
  ) async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      dialogTitle: 'Importar STEP',
    );
    return selected?.path;
  }

  String _managedStepFriendlyError(Object error) {
    if (error is UnsupportedError) {
      return 'A importação STEP não está disponível neste ambiente.';
    }
    if (error is FormatException) {
      return 'O arquivo STEP é inválido ou incompatível.';
    }
    return 'Não foi possível importar a peça STEP. Verifique o arquivo e tente novamente.';
  }

  Future<void> pickAndImport(CadImportFormat format) async {
    final project = projects.current;
    if (project == null) {
      message = 'Create or open a project before importing CAD files.';
      notifyListeners();
      return;
    }
    final selectedFile = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: _importExtensions(format),
      dialogTitle: 'Import ${format.name.toUpperCase()}',
    );
    final sourcePath = selectedFile?.path;
    if (sourcePath == null) return;
    busy = true;
    progress = .05;
    message = 'Validating ${format.name.toUpperCase()} file...';
    notifyListeners();
    try {
      final directory = await projectRepository.directoryFor(project.id);
      if (runtime.document?.projectId != project.id) {
        await runtime.open(project.id, directory);
      }
      final api = ImportExportApi(
        kernel: kernels.active,
        repository: importExportRepository,
      );
      final imported = await api.import(
        CadImportRequest(
          projectId: project.id,
          projectDirectory: directory,
          source: File(sourcePath),
          format: format,
        ),
      );
      final mesh = imported.mesh;
      KernelMeshGeometry? geometry;
      if (mesh != null && kernels.active is MeshGeometryKernelAPI) {
        geometry = await (kernels.active as MeshGeometryKernelAPI).inspectMesh(
          mesh,
        );
      }
      await runtime.registerImport(imported, geometry: geometry);
      progress = 1;
      message =
          '${format.name.toUpperCase()} imported and registered in the project.';
    } catch (error) {
      message = _friendly(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pickAndExport(CadExportFormat format) async {
    final project = projects.current;
    final shape = await runtime.officialExportShape();
    if (project == null) {
      message = 'Create or open a project before exporting CAD files.';
      notifyListeners();
      return;
    }
    if (shape == null) {
      message =
          'STEP/IGES/STL export requires a validated BRep shape. An imported mesh is not converted automatically.';
      notifyListeners();
      return;
    }
    final destinationUri = await FilePicker.saveFile(
      dialogTitle: 'Export ${format.name.toUpperCase()}',
      fileName: 'export.${_exportExtensions(format).first}',
      bytes: Uint8List(0),
      type: FileType.custom,
      allowedExtensions: _exportExtensions(format),
    );
    if (destinationUri == null) return;
    final destination = destinationUri.toFilePath();
    busy = true;
    progress = .05;
    message = 'Validating geometry and topology...';
    notifyListeners();
    try {
      final directory = await projectRepository.directoryFor(project.id);
      final api = ImportExportApi(
        kernel: kernels.active,
        repository: importExportRepository,
      );
      await api.export(
        CadExportRequest(
          projectId: project.id,
          projectDirectory: directory,
          destination: File(destination),
          format: format,
          shape: shape,
        ),
      );
      progress = 1;
      message = '${format.name.toUpperCase()} exported and validated.';
    } catch (error) {
      message = _friendly(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> restoreProjectGeometry(String projectId) async {
    final directory = await projectRepository.directoryFor(projectId);
    await runtime.open(projectId, directory);
    if (runtime.activeImport != null) {
      message = 'CAD document restored.';
      notifyListeners();
      return;
    }
    final history = File(
      path.join(directory.path, 'CAD', 'ImportHistory', 'history.jsonl'),
    );
    if (!await history.exists()) {
      setStatus('Project opened without imported geometry.');
      return;
    }
    final records = (await history.readAsLines())
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .where((record) => record['format'] == CadImportFormat.stl.name)
        .toList();
    if (records.isEmpty) {
      setStatus('Project has no registered STL import.');
      return;
    }
    final record = records.last;
    final registeredPath = record['registeredPath'] as String;
    final source = File(registeredPath);
    if (!await source.exists()) {
      throw StateError('Registered project STL is missing: $registeredPath');
    }
    final kernel = kernels.active;
    if (kernel is! MeshGeometryKernelAPI) {
      throw StateError('Active Geometry Kernel cannot restore STL geometry.');
    }
    final meshKernel = kernel as MeshGeometryKernelAPI;
    busy = true;
    message = 'Restoring registered STL geometry...';
    notifyListeners();
    try {
      final mesh = await meshKernel.importStl(
        registeredPath,
        projectId: projectId,
      );
      final geometry = await meshKernel.inspectMesh(mesh);
      final imported = ImportedCadDocument(
        id: mesh.persistentId,
        projectId: projectId,
        sourcePath: record['sourcePath'] as String,
        format: CadImportFormat.stl,
        registeredPath: registeredPath,
        validation: (record['validation'] as List? ?? const []).cast<String>(),
        mesh: mesh,
      );
      await runtime.registerImport(imported, geometry: geometry);
      message = 'Project STL, references, Sketch and surfaces restored.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> closeProject() async {
    await runtime.close();
    message = 'Project closed.';
    notifyListeners();
  }

  List<String> _importExtensions(CadImportFormat format) => switch (format) {
    CadImportFormat.stl => ['stl'],
    CadImportFormat.step => ['step', 'stp'],
    CadImportFormat.iges => ['iges', 'igs'],
    CadImportFormat.obj => ['obj'],
    CadImportFormat.ply => ['ply'],
  };
  List<String> _exportExtensions(CadExportFormat format) => switch (format) {
    CadExportFormat.step => ['step', 'stp'],
    CadExportFormat.iges => ['iges', 'igs'],
    CadExportFormat.stl => ['stl'],
    CadExportFormat.obj => ['obj'],
  };
  String _friendly(Object error) => error.toString().replaceFirst(
    RegExp(
      r'^(Exception|StateError|Unsupported operation|FormatException):\s*',
    ),
    '',
  );

  @override
  void dispose() {
    runtime.dispose();
    super.dispose();
  }
}
