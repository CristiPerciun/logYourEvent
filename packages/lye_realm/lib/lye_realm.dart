/// Log Your Event (LYE) — Realm store.
///
/// `RealmLyeStore` keeps sealed events in a local, optionally encrypted
/// Realm file: the durable buffer of a server instance between two exports,
/// or the local journal of a desktop or mobile client between two shipments.
/// Realm has no web build: on Flutter Web use `MemoryLyeStore`.
library;

export 'src/models.dart' show LyeChainHeadRow, LyeEventRow;
export 'src/realm_keys.dart';
export 'src/realm_lye_store.dart';
