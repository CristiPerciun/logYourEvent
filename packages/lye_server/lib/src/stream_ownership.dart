/// Who may append to a client stream.
///
/// A stream is bound to the first authenticated actor that ships it; from
/// then on only that actor can extend it. Without this, an attacker holding
/// any valid session could forge the trail of another user by shipping a
/// perfectly chained stream under their node identifier.
abstract class StreamOwnership {
  /// Actor bound to [streamId], or null when the stream is new.
  Future<String?> ownerOf(String streamId);

  /// Binds [streamId] to [actorRef]. Must not overwrite an existing binding.
  Future<void> bind(String streamId, String actorRef);
}

/// In-memory ownership, for tests and single-instance deployments.
class MemoryStreamOwnership implements StreamOwnership {
  final Map<String, String> _owners = <String, String>{};

  @override
  Future<String?> ownerOf(String streamId) async => _owners[streamId];

  @override
  Future<void> bind(String streamId, String actorRef) async {
    _owners.putIfAbsent(streamId, () => actorRef);
  }
}
