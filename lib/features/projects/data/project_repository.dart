import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../core/logger/app_logger.dart';
import '../../../core/engineering/repositories/repository.dart';
import '../../../core/projects/project_manifest.dart';
import '../../../core/storage/image_storage_service.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../../core/utils/id_generator.dart';
import '../models/project.dart';
import '../models/project_history.dart';
import '../models/project_status.dart';
import 'project_serializer.dart';

class ProjectRepository implements Repository<Project, String> {
  ProjectRepository({
    LocalStorageService? storage,
    ImageStorageService? imageStorage,
  }) : _storage = storage ?? LocalStorageService(),
       _imageStorage = imageStorage ?? ImageStorageService.instance;

  final LocalStorageService _storage;
  final ImageStorageService _imageStorage;

  static const requiredFolders = [
    'Images',
    'Mesh',
    'Reconstruction',
    'CAD',
    'CAD/Shapes',
    'CAD/Topology',
    'CAD/Features',
    'CAD/History',
    'CAD/FeatureGraph',
    'SurfacePlanning',
    'SurfaceCandidates',
    'SurfaceStrategies',
    'SurfaceGraph',
    'GeneratedSurfaces',
    'SurfaceHistory',
    'SurfaceRegistry',
    'SurfaceDiagnostics',
    'HybridSurface',
    'SurfaceNetwork',
    'HybridStrategies',
    'PatchPlanning',
    'ReconstructionNetwork',
    'Kernel',
    'KernelCache',
    'KernelDiagnostics',
    'NativeShapes',
    'STL',
    'Reports',
    'Textures',
    'Snapshots',
    'AI',
    'SmartRegions',
    'FEL',
    'References',
    'Sketch',
    'Surfaces',
    'Topology',
    'Features',
    'Sessions',
    'Decisions',
    'Workspace',
  ];

  Future<Project> create({
    required String name,
    required String client,
    String description = '',
  }) async {
    final now = DateTime.now();
    final project = Project(
      id: IdGenerator.generate(),
      name: name,
      client: client,
      description: description,
      createdAt: now,
      status: ProjectStatus.created,
      history: ProjectHistory(lastEditedAt: now),
    );
    await save(project);
    return open(project);
  }

  Future<Directory> ensureStructure(String projectId) async {
    final jobs = await _storage.getJobsDirectory();
    final directory = Directory(path.join(jobs.path, projectId));
    await directory.create(recursive: true);
    for (final folder in requiredFolders) {
      await Directory(
        path.join(directory.path, folder),
      ).create(recursive: true);
    }
    return directory;
  }

  Future<Directory> directoryFor(String projectId) =>
      ensureStructure(projectId);

  @override
  Future<void> save(Project project) async {
    final directory = await ensureStructure(project.id);
    final file = File(path.join(directory.path, 'job.json'));
    await _atomicText(
      file,
      const JsonEncoder.withIndent(
        ' ',
      ).convert(ProjectSerializer.toJson(project)),
    );
    await _saveManifest(directory, project);
  }

  Future<void> _saveManifest(Directory directory, Project project) async {
    final file = File(path.join(directory.path, 'project.manifest.json'));
    final existing = await file.exists()
        ? ProjectManifest.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>,
          )
        : null;
    final now = DateTime.now();
    final manifest = ProjectManifest(
      projectId: project.id,
      schemaVersion: ProjectManifest.currentVersion,
      createdAt: existing?.createdAt ?? project.createdAt,
      updatedAt: now,
    );
    await _atomicText(
      file,
      const JsonEncoder.withIndent(' ').convert(manifest.toJson()),
    );
  }

  Future<void> _atomicText(File target, String value) async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final temporary = File('${target.path}.tmp-$suffix');
    final backup = File('${target.path}.bak-$suffix');
    var installed = false;
    try {
      await temporary.writeAsString(value, flush: true);
      if (await target.exists()) await target.rename(backup.path);
      await temporary.rename(target.path);
      installed = true;
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on Object {
          // Best-effort cleanup only.
        }
      }
    } catch (_) {
      if (!installed && !await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
      if (installed && await backup.exists()) {
        try {
          await backup.delete();
        } on Object {
          // Best-effort cleanup only.
        }
      }
    }
  }

  @override
  Future<Project?> findById(String id) async {
    final jobs = await _storage.getJobsDirectory();
    final directory = Directory(path.join(jobs.path, id));
    final file = File(path.join(directory.path, 'job.json'));
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final project = ProjectSerializer.fromJson(json);
      return _withDiskStatistics(project, directory);
    } catch (error, stackTrace) {
      AppLogger.log(
        'Could not load project $id',
        level: LogLevel.error,
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  @override
  Future<List<Project>> findAll() async {
    final jobs = await _storage.getJobsDirectory();
    final projects = <Project>[];
    await for (final entry in jobs.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final project = await findById(path.basename(entry.path));
      if (project != null) projects.add(project);
    }
    return projects;
  }

  Future<Project> open(Project project) async {
    final opened = project.copyWith(
      history: project.history.copyWith(lastOpenedAt: DateTime.now()),
    );
    await save(opened);
    final root = await _storage.getRootDirectory();
    await File(
      path.join(root.path, 'active_project'),
    ).writeAsString(opened.id, flush: true);
    return opened;
  }

  Future<Project?> restoreCurrent() async {
    final root = await _storage.getRootDirectory();
    final currentMarker = File(path.join(root.path, 'active_project'));
    final legacyMarker = File(path.join(root.path, 'active_job'));
    final marker = await currentMarker.exists() ? currentMarker : legacyMarker;
    if (!await marker.exists()) return null;
    final id = (await marker.readAsString()).trim();
    final project = id.isEmpty ? null : await findById(id);
    if (project == null || project.isArchived) {
      await clearCurrent();
      return null;
    }
    return open(project);
  }

  Future<void> clearCurrent() async {
    final root = await _storage.getRootDirectory();
    for (final name in ['active_project', 'active_job']) {
      final marker = File(path.join(root.path, name));
      if (await marker.exists()) await marker.delete();
    }
  }

  @override
  Future<void> delete(Project project) async {
    final jobs = await _storage.getJobsDirectory();
    final directory = Directory(path.join(jobs.path, project.id));
    if (!path.isWithin(jobs.path, directory.path)) {
      throw StateError('Invalid project directory');
    }
    if (await directory.exists()) await directory.delete(recursive: true);
    if (await _currentProjectId() == project.id) await clearCurrent();
  }

  Future<Project> refreshStatistics(Project project) async {
    final directory = await ensureStructure(project.id);
    final updated = await _withDiskStatistics(project, directory);
    await save(updated);
    return updated;
  }

  Future<Project> _withDiskStatistics(
    Project project,
    Directory directory,
  ) async {
    final images = await _imageStorage.loadImages(directory);
    return project.copyWith(
      statistics: project.statistics.copyWith(photoCount: images.length),
      thumbnailPath: images.isEmpty ? null : images.last.path,
      clearThumbnail: images.isEmpty,
    );
  }

  Future<String?> _currentProjectId() async {
    final root = await _storage.getRootDirectory();
    for (final name in ['active_project', 'active_job']) {
      final marker = File(path.join(root.path, name));
      if (await marker.exists()) return (await marker.readAsString()).trim();
    }
    return null;
  }
}
