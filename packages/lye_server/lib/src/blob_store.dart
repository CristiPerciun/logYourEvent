import 'dart:io';

import 'package:path/path.dart' as p;

/// Minimal object storage abstraction for anchors and exported files.
///
/// The production implementation targets the S3 API of Hetzner Object
/// Storage (bucket in HEL1, versioning on) and lives in the consuming
/// server, which already holds the credentials and the S3 client; this
/// package ships the interface and a directory-backed implementation.
abstract class BlobStore {
  Future<void> put(
    String key,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
  });
  Future<List<int>?> get(String key);
  Future<List<String>> list(String prefix);
}

/// Blob store on a local directory (tests, single-server deployments, a
/// mounted off-site volume).
class LocalDirectoryBlobStore implements BlobStore {
  LocalDirectoryBlobStore(this.root);

  final String root;

  String _pathFor(String key) => p.joinAll(<String>[root, ...key.split('/')]);

  @override
  Future<void> put(
    String key,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    final file = File(_pathFor(key));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<List<int>?> get(String key) async {
    final file = File(_pathFor(key));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<List<String>> list(String prefix) async {
    final dir = Directory(root);
    if (!await dir.exists()) return <String>[];
    final keys = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final key = p.split(p.relative(entity.path, from: root)).join('/');
      if (key.startsWith(prefix)) keys.add(key);
    }
    keys.sort();
    return keys;
  }
}
