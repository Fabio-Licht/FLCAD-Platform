import 'dart:convert';
import 'dart:io';
import '../models/kernel_models.dart';

/// Persists only portable metadata. Native `TopoDS_Shape` objects stay private
/// to the process registry and are persisted through BREP by the kernel API.
class OpenCascadeRuntimeRepository {
  const OpenCascadeRuntimeRepository();

  Future<void> ensureStructure(Directory project) async {
    for (final name in const [
      'Kernel',
      'KernelCache',
      'KernelDiagnostics',
      'NativeShapes',
    ]) {
      await Directory(
        '${project.path}${Platform.pathSeparator}$name',
      ).create(recursive: true);
    }
  }

  Future<File> saveShapeMetadata(Directory project, ShapeHandle handle) async {
    await ensureStructure(project);
    final file = File(
      '${project.path}${Platform.pathSeparator}NativeShapes${Platform.pathSeparator}${_safeFileStem(handle.persistentId)}.json',
    );
    return file.writeAsString(jsonEncode(handle.toJson()), flush: true);
  }

  String _safeFileStem(String value) => value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '_');

  Future<File> saveDiagnostics(
    Directory project,
    String id,
    Map<String, dynamic> data,
  ) async {
    await ensureStructure(project);
    final file = File(
      '${project.path}${Platform.pathSeparator}KernelDiagnostics${Platform.pathSeparator}$id.json',
    );
    return file.writeAsString(jsonEncode(data), flush: true);
  }
}
