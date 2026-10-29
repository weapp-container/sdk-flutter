/// Read-only proof shared by the native view queue and development startup /
/// navigation coordinators. This never acknowledges a layout or substitutes a
/// newer observation for the submitted immutable request.
BigInt? _layoutSequence(Object? value) {
  if (value is! String || !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value)) {
    return null;
  }
  final number = BigInt.parse(value);
  return number <= BigInt.parse('18446744073709551615') ? number : null;
}

/// A cancellation is expected only when the native owner proves that this
/// queued observation has been superseded. A healthy frame alone is not proof.
bool supersededHostLayout(Map<String, Object?> observation, String revision,
    Map<String, Object?> state) {
  final owner = observation['ownerId'];
  final surface = _layoutSequence(observation['surfaceGeneration']);
  final sequence = _layoutSequence(observation['observationId']);
  final attemptedRevision = _layoutSequence(revision);
  final currentSurface = state['hostSurface'];
  final health = state['executionHealth'];
  if (observation['schemaVersion'] != 1 ||
      state['schemaVersion'] != 1 ||
      _layoutSequence(owner) == null ||
      surface == null ||
      sequence == null ||
      attemptedRevision == null ||
      state['ownerId'] != owner ||
      currentSurface is! Map ||
      currentSurface['ownerId'] != owner ||
      !((state['status'] == 'ready' && _healthyHostLayoutOwner(health)) ||
          _typedEmptyHostLayoutOwner(observation, state))) return false;
  final activeSurface = _layoutSequence(currentSurface['surfaceGeneration']);
  if (activeSurface == null || activeSurface < surface) return false;
  bool newer(Object? value, {required bool accepted}) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['ownerId'] != owner ||
        value['surfaceGeneration'] != currentSurface['surfaceGeneration']) {
      return false;
    }
    final next = _layoutSequence(value['observationId']);
    if (next == null || next < sequence) return false;
    final nextRevision =
        accepted ? _layoutSequence(value['layoutRevision']) : null;
    if (accepted && nextRevision == null) return false;
    // Observation identity, rather than an arbitrary error message or a
    // coincidentally identical rectangle, establishes native supersession.
    if (next > sequence) return true;
    if (!accepted || activeSurface != surface) return false;
    return nextRevision != null && nextRevision > attemptedRevision;
  }

  return newer(state['pendingHostLayout'], accepted: false) ||
      newer(state['acceptedLayout'], accepted: true);
}

bool _healthyHostLayoutOwner(Object? value) =>
    value is Map &&
    value['schemaVersion'] == 1 &&
    value['requiresRestart'] == false &&
    value['appServiceFault'] == null &&
    value['viewFault'] == null &&
    value['navigationFault'] == null;

bool _typedEmptyHostLayoutOwner(
    Map<String, Object?> observation, Map<String, Object?> state) {
  if (state['status'] != 'empty' ||
      !const [
        'executionHealth',
        'sessionId',
        'page',
        'acceptedPackIdentity',
        'acceptedLayout'
      ].every((key) => state.containsKey(key) && state[key] == null) ||
      !const ['sessionId', 'pageId'].every((key) => observation[key] == null)) {
    return false;
  }
  final pending = state['pendingHostLayout'];
  if (pending is! Map ||
      !const ['sessionId', 'pageId'].every((key) => pending[key] == null)) {
    return false;
  }
  return _validEmptyLayoutMetrics(observation['windowMetrics']) &&
      _validEmptyLayoutMetrics(pending['windowMetrics']);
}

bool _validEmptyLayoutMetrics(Object? metrics) {
  if (metrics is! Map) return false;
  for (final name in const [
    'windowWidth',
    'windowHeight',
    'screenWidth',
    'screenHeight',
    'pixelRatio',
    'statusBarHeight',
    'screenTop'
  ]) {
    final value = metrics[name];
    if (value is! num || !value.isFinite) return false;
    if (const ['windowWidth', 'windowHeight', 'screenWidth', 'screenHeight']
            .contains(name) &&
        (value <= 0 || value > 16384 || value % 1 != 0)) return false;
    if (name == 'pixelRatio' && value <= 0 ||
        name == 'statusBarHeight' && value < 0) return false;
  }
  return metrics['deviceOrientation'] == 'portrait' ||
      metrics['deviceOrientation'] == 'landscape';
}
