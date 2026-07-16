/// Web/no-IO mirror of `vector_cache_dir_io.dart`. See that file for why this
/// conditional pair exists at all.
///
/// There is no filesystem here, so there is no offline tile cache either — the
/// basemap simply streams. Calling this is a programming error rather than a
/// degraded mode, hence the throw.
typedef VectorCacheDir = String;

Future<VectorCacheDir> vectorCacheDir() async =>
    throw UnsupportedError('The vector tile cache folder requires dart:io.');
