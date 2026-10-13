import 'dart:convert';

import '../layout/panel_identity.dart';

/// Protocol version exchanged in the handshake.
///
/// The bridge and the panel shell must agree on the major version; a panel
/// asking for a newer minor version is rejected because the main process cannot
/// know the semantics it expects.
class PanelProtocolVersion {
  const PanelProtocolVersion(this.major, this.minor);

  static const PanelProtocolVersion current = PanelProtocolVersion(1, 0);

  final int major;
  final int minor;

  bool accepts(PanelProtocolVersion other) =>
      other.major == major && other.minor <= minor;

  Map<String, Object?> toJson() => {'major': major, 'minor': minor};

  static PanelProtocolVersion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final major = raw['major'];
    final minor = raw['minor'];
    if (major is! num || minor is! num) return null;
    return PanelProtocolVersion(major.toInt(), minor.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is PanelProtocolVersion &&
      other.major == major &&
      other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}

/// Capabilities a panel declares in [PanelHello]; the bridge only routes
/// actions the panel was granted.
abstract final class PanelCapabilities {
  static const String explorer = 'explorer';
  static const String selection = 'selection';
  static const String visibility = 'visibility';

  static const List<String> all = [explorer, selection, visibility];
}

/// Typed protocol failures. Every rejection carries a code the panel can log or
/// surface without parsing strings.
enum PanelErrorCode {
  unsupportedVersion,
  malformedMessage,
  payloadTooLarge,
  unknownAction,
  unauthorizedCapability,
  invalidPayload,
  staleSession,
  staleProject,
  outOfOrderRevision,

  /// The same requestId arrived again with a different payload: replaying the
  /// cached answer would be wrong, so the bridge refuses it explicitly.
  conflictingRequestId,
  notReady,
  internalError,
}

class PanelProtocolException implements Exception {
  const PanelProtocolException(this.code, this.message, [this.details]);

  final PanelErrorCode code;
  final String message;
  final Map<String, Object?>? details;

  @override
  String toString() => 'PanelProtocolException(${code.name}): $message';
}

/// Size/shape limits enforced before any payload reaches the CAD session.
class PanelProtocolLimits {
  const PanelProtocolLimits({
    this.maxMessageBytes = 64 * 1024,
    this.maxSelectionIds = 512,
    this.maxIdLength = 160,
    this.maxResultCache = 128,
    this.maxViewModelEntities = 2000,
  });

  final int maxMessageBytes;
  final int maxSelectionIds;
  final int maxIdLength;
  final int maxResultCache;
  final int maxViewModelEntities;
}

/// Byte size of a message as it would travel over a real transport.
int panelPayloadSize(Map<String, Object?> message) {
  try {
    return utf8.encode(jsonEncode(message)).length;
  } on Object {
    return -1;
  }
}

/// The single whitelist of actions a panel may request.
///
/// There is no generic "run command" action: each entry names the capability it
/// needs and validates its own parameters before the bridge touches anything.
class PanelActionSpec {
  const PanelActionSpec({
    required this.name,
    required this.capability,
    required this.allowedParams,
    required this.validate,
  });

  final String name;
  final String capability;
  final Set<String> allowedParams;
  final void Function(Map<String, Object?> params, PanelProtocolLimits limits)
  validate;
}

const String panelActionSelectionSet = 'selection.set';
const String panelActionVisibilitySet = 'visibility.set';

final Map<String, PanelActionSpec> panelActionCatalog = {
  panelActionSelectionSet: PanelActionSpec(
    name: panelActionSelectionSet,
    capability: PanelCapabilities.selection,
    allowedParams: const {'ids'},
    validate: (params, limits) {
      final ids = params['ids'];
      if (ids is! List) {
        throw const PanelProtocolException(
          PanelErrorCode.invalidPayload,
          'selection.set requires an "ids" list.',
        );
      }
      if (ids.length > limits.maxSelectionIds) {
        throw PanelProtocolException(
          PanelErrorCode.payloadTooLarge,
          'selection.set received ${ids.length} ids '
          '(limit ${limits.maxSelectionIds}).',
        );
      }
      final seen = <String>{};
      for (final id in ids) {
        if (id is! String || id.isEmpty || id.length > limits.maxIdLength) {
          throw const PanelProtocolException(
            PanelErrorCode.invalidPayload,
            'selection.set ids must be non-empty bounded strings.',
          );
        }
        if (!seen.add(id)) {
          throw const PanelProtocolException(
            PanelErrorCode.invalidPayload,
            'selection.set ids must be unique.',
          );
        }
      }
    },
  ),
  panelActionVisibilitySet: PanelActionSpec(
    name: panelActionVisibilitySet,
    capability: PanelCapabilities.visibility,
    allowedParams: const {'id', 'visible'},
    validate: (params, limits) {
      final id = params['id'];
      final visible = params['visible'];
      if (id is! String || id.isEmpty || id.length > limits.maxIdLength) {
        throw const PanelProtocolException(
          PanelErrorCode.invalidPayload,
          'visibility.set requires a bounded "id".',
        );
      }
      if (visible is! bool) {
        throw const PanelProtocolException(
          PanelErrorCode.invalidPayload,
          'visibility.set requires a boolean "visible".',
        );
      }
    },
  ),
};

abstract final class PanelMessageType {
  static const String hello = 'hello';
  static const String snapshot = 'snapshot';
  static const String intent = 'intent';
  static const String result = 'result';
  static const String lifecycle = 'lifecycle';
}

abstract class PanelMessage {
  const PanelMessage();

  String get type;

  Map<String, Object?> toJson();
}

class PanelHello extends PanelMessage {
  const PanelHello({
    required this.panelId,
    required this.protocolVersion,
    this.capabilities = PanelCapabilities.all,
    this.clientInstanceId = 'panel',
    this.resync = false,
  });

  final PanelId panelId;
  final PanelProtocolVersion protocolVersion;
  final List<String> capabilities;
  final String clientInstanceId;

  /// True when the panel lost a revision and needs a full snapshot again.
  final bool resync;

  @override
  String get type => PanelMessageType.hello;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'panelId': panelId.name,
    'protocolVersion': protocolVersion.toJson(),
    'capabilities': capabilities,
    'clientInstanceId': clientInstanceId,
    'resync': resync,
  };

  static PanelHello fromJson(Map<Object?, Object?> raw) {
    final panelId = panelIdFromName(raw['panelId'] as String? ?? '');
    final version = PanelProtocolVersion.fromJson(raw['protocolVersion']);
    if (panelId == null) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'hello requires a known panelId.',
      );
    }
    if (version == null) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'hello requires a protocolVersion.',
      );
    }
    final capabilities = raw['capabilities'];
    return PanelHello(
      panelId: panelId,
      protocolVersion: version,
      capabilities: capabilities is List
          ? capabilities.whereType<String>().toList(growable: false)
          : const [],
      clientInstanceId: raw['clientInstanceId'] as String? ?? 'panel',
      resync: raw['resync'] as bool? ?? false,
    );
  }
}

class PanelSnapshot extends PanelMessage {
  const PanelSnapshot({
    required this.panelId,
    required this.sessionId,
    required this.revision,
    required this.viewModel,
    this.projectId,
    this.full = true,
    this.changedKeys = const [],
    this.omittedKeys = const [],
  });

  final PanelId panelId;
  final int sessionId;
  final String? projectId;

  /// **Protocol sequence**, not the document revision: monotonically increasing
  /// per session and bumped by the bridge on every delivery, so it orders the
  /// messages of one panel channel. The CAD state revision travels inside the
  /// view-model ([PanelViewModelKeys.stateRevision]).
  final int revision;

  /// Full projection or an incremental patch.
  final bool full;
  final Map<String, Object?> viewModel;
  final List<String> changedKeys;

  /// Heavy keys the bridge had to omit to respect the message budget (today
  /// `PanelViewModelKeys.entities`). Never a silent truncation: the panel can
  /// tell the operator that a paginated projection is pending.
  final List<String> omittedKeys;

  @override
  String get type => PanelMessageType.snapshot;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'panelId': panelId.name,
    'sessionId': sessionId,
    if (projectId != null) 'projectId': projectId,
    'revision': revision,
    'full': full,
    if (!full) 'changedKeys': changedKeys,
    if (omittedKeys.isNotEmpty) 'omittedKeys': omittedKeys,
    'viewModel': viewModel,
  };

  static PanelSnapshot fromJson(Map<Object?, Object?> raw) {
    final panelId = panelIdFromName(raw['panelId'] as String? ?? '');
    final sessionId = raw['sessionId'];
    final revision = raw['revision'];
    if (panelId == null || sessionId is! num || revision is! num) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'snapshot requires panelId, sessionId and revision.',
      );
    }
    final viewModel = raw['viewModel'];
    if (viewModel is! Map) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'snapshot requires a viewModel object.',
      );
    }
    final changed = raw['changedKeys'];
    final omitted = raw['omittedKeys'];
    return PanelSnapshot(
      panelId: panelId,
      sessionId: sessionId.toInt(),
      projectId: raw['projectId'] as String?,
      revision: revision.toInt(),
      full: raw['full'] as bool? ?? true,
      changedKeys: changed is List
          ? changed.whereType<String>().toList(growable: false)
          : const [],
      omittedKeys: omitted is List
          ? omitted.whereType<String>().toList(growable: false)
          : const [],
      viewModel: {
        for (final entry in viewModel.entries)
          if (entry.key is String) entry.key as String: entry.value,
      },
    );
  }
}

class PanelIntent extends PanelMessage {
  const PanelIntent({
    required this.panelId,
    required this.sessionId,
    required this.action,
    required this.requestId,
    this.projectId,
    this.params = const {},
    this.baseRevision,
  });

  final PanelId panelId;
  final int sessionId;
  final String? projectId;
  final String action;
  final Map<String, Object?> params;
  final String requestId;

  /// Revision the panel believed it was acting on (optional).
  final int? baseRevision;

  @override
  String get type => PanelMessageType.intent;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'panelId': panelId.name,
    'sessionId': sessionId,
    if (projectId != null) 'projectId': projectId,
    'action': action,
    'params': params,
    'requestId': requestId,
    if (baseRevision != null) 'baseRevision': baseRevision,
  };

  static PanelIntent fromJson(Map<Object?, Object?> raw) {
    final panelId = panelIdFromName(raw['panelId'] as String? ?? '');
    final sessionId = raw['sessionId'];
    final action = raw['action'];
    final requestId = raw['requestId'];
    if (panelId == null ||
        sessionId is! num ||
        action is! String ||
        action.isEmpty ||
        requestId is! String ||
        requestId.isEmpty) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'intent requires panelId, sessionId, action and requestId.',
      );
    }
    final params = raw['params'];
    final baseRevision = raw['baseRevision'];
    return PanelIntent(
      panelId: panelId,
      sessionId: sessionId.toInt(),
      projectId: raw['projectId'] as String?,
      action: action,
      params: params is Map
          ? {
              for (final entry in params.entries)
                if (entry.key is String) entry.key as String: entry.value,
            }
          : const {},
      requestId: requestId,
      baseRevision: baseRevision is num ? baseRevision.toInt() : null,
    );
  }
}

class PanelResult extends PanelMessage {
  const PanelResult({
    required this.requestId,
    required this.panelId,
    required this.ok,
    required this.revision,
    this.sessionId,
    this.errorCode,
    this.message,
    this.replayed = false,
  });

  final String requestId;
  final PanelId panelId;
  final bool ok;
  final int revision;

  /// Session the answer belongs to; a panel ignores answers from a previous
  /// session (late replies after a project switch).
  final int? sessionId;
  final PanelErrorCode? errorCode;
  final String? message;

  /// True when the answer came from the idempotency cache.
  final bool replayed;

  @override
  String get type => PanelMessageType.result;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'panelId': panelId.name,
    'requestId': requestId,
    'ok': ok,
    'revision': revision,
    if (sessionId != null) 'sessionId': sessionId,
    if (errorCode != null) 'errorCode': errorCode!.name,
    if (message != null) 'message': message,
    if (replayed) 'replayed': true,
  };

  static PanelResult fromJson(Map<Object?, Object?> raw) {
    final panelId = panelIdFromName(raw['panelId'] as String? ?? '');
    final requestId = raw['requestId'];
    final revision = raw['revision'];
    if (panelId == null || requestId is! String || revision is! num) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'result requires panelId, requestId and revision.',
      );
    }
    final code = raw['errorCode'];
    final sessionId = raw['sessionId'];
    return PanelResult(
      requestId: requestId,
      panelId: panelId,
      ok: raw['ok'] as bool? ?? false,
      revision: revision.toInt(),
      sessionId: sessionId is num ? sessionId.toInt() : null,
      errorCode: code is String ? _errorFromName(code) : null,
      message: raw['message'] as String?,
      replayed: raw['replayed'] as bool? ?? false,
    );
  }
}

class PanelLifecycle extends PanelMessage {
  const PanelLifecycle({
    required this.panelId,
    required this.state,
    this.sessionId,
    this.projectId,
    this.reason,
  });

  final PanelId panelId;
  final PanelLifecycleState state;
  final int? sessionId;
  final String? projectId;
  final String? reason;

  @override
  String get type => PanelMessageType.lifecycle;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'panelId': panelId.name,
    'state': state.name,
    if (sessionId != null) 'sessionId': sessionId,
    if (projectId != null) 'projectId': projectId,
    if (reason != null) 'reason': reason,
  };

  static PanelLifecycle fromJson(Map<Object?, Object?> raw) {
    final panelId = panelIdFromName(raw['panelId'] as String? ?? '');
    final state = _lifecycleFromName(raw['state'] as String?);
    if (panelId == null || state == null) {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'lifecycle requires panelId and state.',
      );
    }
    final sessionId = raw['sessionId'];
    return PanelLifecycle(
      panelId: panelId,
      state: state,
      sessionId: sessionId is num ? sessionId.toInt() : null,
      projectId: raw['projectId'] as String?,
      reason: raw['reason'] as String?,
    );
  }
}

enum PanelLifecycleState { connected, ready, suspended, disconnected }

/// Decodes any transport payload into a typed message, enforcing the size limit
/// and rejecting unknown shapes with typed errors.
PanelMessage decodePanelMessage(
  Object? raw, {
  PanelProtocolLimits limits = const PanelProtocolLimits(),
}) {
  if (raw is String) {
    if (utf8.encode(raw).length > limits.maxMessageBytes) {
      throw PanelProtocolException(
        PanelErrorCode.payloadTooLarge,
        'message exceeds ${limits.maxMessageBytes} bytes.',
      );
    }
    try {
      raw = jsonDecode(raw);
    } on Object {
      throw const PanelProtocolException(
        PanelErrorCode.malformedMessage,
        'payload is not valid JSON.',
      );
    }
  }
  if (raw is! Map) {
    throw const PanelProtocolException(
      PanelErrorCode.malformedMessage,
      'payload is not an object.',
    );
  }
  final type = raw['type'];
  if (type is! String) {
    throw const PanelProtocolException(
      PanelErrorCode.malformedMessage,
      'payload has no message type.',
    );
  }
  return switch (type) {
    PanelMessageType.hello => PanelHello.fromJson(raw),
    PanelMessageType.snapshot => PanelSnapshot.fromJson(raw),
    PanelMessageType.intent => PanelIntent.fromJson(raw),
    PanelMessageType.result => PanelResult.fromJson(raw),
    PanelMessageType.lifecycle => PanelLifecycle.fromJson(raw),
    _ => throw PanelProtocolException(
      PanelErrorCode.malformedMessage,
      'unknown message type "$type".',
    ),
  };
}

/// Validates a whitelisted action before the main session applies anything.
PanelActionSpec validatePanelAction({
  required String action,
  required Map<String, Object?> params,
  required Set<String> grantedCapabilities,
  PanelProtocolLimits limits = const PanelProtocolLimits(),
}) {
  final spec = panelActionCatalog[action];
  if (spec == null) {
    throw PanelProtocolException(
      PanelErrorCode.unknownAction,
      'action "$action" is not part of the whitelist.',
    );
  }
  if (!grantedCapabilities.contains(spec.capability)) {
    throw PanelProtocolException(
      PanelErrorCode.unauthorizedCapability,
      'capability "${spec.capability}" was not granted to this panel.',
    );
  }
  for (final key in params.keys) {
    if (!spec.allowedParams.contains(key)) {
      throw PanelProtocolException(
        PanelErrorCode.invalidPayload,
        'unexpected parameter "$key" for $action.',
      );
    }
  }
  spec.validate(params, limits);
  return spec;
}

PanelErrorCode? _errorFromName(String name) {
  for (final code in PanelErrorCode.values) {
    if (code.name == name) return code;
  }
  return null;
}

PanelLifecycleState? _lifecycleFromName(String? name) {
  if (name == null) return null;
  for (final state in PanelLifecycleState.values) {
    if (state.name == name) return state;
  }
  return null;
}
