import 'dart:io' as io;

import 'package:path_provider/path_provider.dart';

/// The folder type [VectorTileLayer.cacheFolder] expects on IO targets.
///
/// `vector_map_tiles` types that callback through its own conditional typedef
/// (`Directory` = `dart:io`'s on IO, `String` on web). Because this project has
/// a `web/` target, the analyzer resolves the package's typedef to the web stub
/// and rejects a plain `dart:io` `Directory`. Mirroring the package's pattern —
/// rather than casting through `dynamic` — keeps the layer type-checking under
/// BOTH resolutions while still handing it a real directory at runtime.
typedef VectorCacheDir = io.Directory;

/// The app-owned folder backing the vector basemap's on-disk tile cache.
/// Created on first use.
Future<io.Directory> resolveVectorCacheDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = io.Directory('${base.path}/vector_tiles');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<VectorCacheDir> vectorCacheDir() => resolveVectorCacheDir();
