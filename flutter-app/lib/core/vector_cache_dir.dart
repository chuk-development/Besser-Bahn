/// Resolves `vectorCacheDir` / `VectorCacheDir` to the IO or stub flavour,
/// mirroring how `vector_map_tiles` types `VectorTileLayer.cacheFolder`.
library;

export 'vector_cache_dir_stub.dart'
    if (dart.library.io) 'vector_cache_dir_io.dart';
