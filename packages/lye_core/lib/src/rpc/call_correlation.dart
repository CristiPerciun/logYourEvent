import '../canonical/canonical_json.dart';
import '../chain/hash_chain.dart';

/// Deterministic correlation of an endpoint call across client and server.
///
/// The Serverpod client offers no way to add a header to a call, so the two
/// sides cannot share a trace identifier over the wire. They can, however,
/// compute the same digest over what both see: endpoint name, method name
/// and the JSON arguments (the client encodes them, the server decodes the
/// very same JSON). The frontend `rpc.call` event and the server
/// `rpc.handle` event carry that digest in their attributes; the timeline
/// tool joins them on `(actor_ref, call_digest)` within a time window.
///
/// Arguments enter the digest, never the trace: only the digest is stored.
abstract final class CallCorrelation {
  /// Key of the digest inside `attrs`.
  static const String attrKey = 'call_digest';

  /// Keys the Serverpod wire format adds around the arguments and that both
  /// sides must drop before digesting: `formatArgs` writes `method` into the
  /// very map the client callbacks receive, and the server merges the URL
  /// query (`auth`, `endpoint`) into `queryParameters`.
  static const Set<String> serverpodEnvelopeKeys = <String>{
    'method',
    'endpoint',
    'auth',
  };

  /// SHA-256 over the canonical JSON of `{e: endpoint, m: method, a: args}`.
  static String digest({
    required String endpoint,
    required String method,
    required Object? jsonArgs,
  }) {
    return HashChain.digestHex(
      canonicalJson(<String, Object?>{
        'e': endpoint,
        'm': method,
        'a': jsonArgs,
      }),
    );
  }

  /// Arguments as decoded on the server, without the envelope keys.
  static Map<String, Object?> stripEnvelope(
    Map<Object?, Object?> queryParameters,
  ) {
    return <String, Object?>{
      for (final entry in queryParameters.entries)
        if (!serverpodEnvelopeKeys.contains(entry.key.toString()))
          entry.key.toString(): entry.value,
    };
  }

  /// `endpoint.method`, the value of the `route` column on the server.
  static String route(String endpoint, String method) => '$endpoint.$method';

  /// Attributes of an `rpc.call` / `rpc.handle` event.
  static Map<String, Object?> attrs({
    required String endpoint,
    required String method,
    required Object? jsonArgs,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    return <String, Object?>{
      'endpoint': endpoint,
      'method': method,
      attrKey: digest(endpoint: endpoint, method: method, jsonArgs: jsonArgs),
      ...extra,
    };
  }
}
