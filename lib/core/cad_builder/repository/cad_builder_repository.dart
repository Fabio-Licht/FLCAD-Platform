import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/cad_models.dart';

class CadBuilderRepository {
  const CadBuilderRepository(this.projectDirectory);
  final Directory projectDirectory;
  Directory get _shapes =>
      Directory(path.join(projectDirectory.path, 'CAD', 'Shapes'));
  Directory get _topology =>
      Directory(path.join(projectDirectory.path, 'CAD', 'Topology'));
  Future<void> initialize() async {
    await _shapes.create(recursive: true);
    await _topology.create(recursive: true);
  }

  Future<void> save(CadEntity entity) async {
    await initialize();
    final target = File(
      path.join(
        _shapes.path,
        '${entity.handle.persistentId.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').replaceAll(RegExp(r'[. ]+$'), '_')}.json',
      ),
    );
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(entity.toJson()), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<List<CadEntity>> loadAll() async {
    await initialize();
    final result = <CadEntity>[];
    await for (final item in _shapes.list()) {
      if (item is File && item.path.endsWith('.json')) {
        result.add(
          CadEntity.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(await item.readAsString()) as Map,
            ),
          ),
        );
      }
    }
    return result;
  }

  Future<void> delete(String id) async {
    final file = File(path.join(_shapes.path, '$id.json'));
    if (await file.exists()) await file.delete();
  }

  Future<void> saveTopology(Map<String, dynamic> topology) async {
    await initialize();
    await File(
      path.join(_topology.path, 'geometry_graph.json'),
    ).writeAsString(jsonEncode(topology), flush: true);
  }
}
