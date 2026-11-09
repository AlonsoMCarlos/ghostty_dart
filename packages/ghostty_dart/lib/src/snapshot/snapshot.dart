/// Terminal snapshots (`snapshot.h`): encode a terminal's complete state to
/// bytes with [VtTerminalSnapshot] and restore it with [SnapshotDecoder].
///
/// **The snapshot format is not covered by libghostty-vt's ABI promise**; do
/// not persist snapshots across library versions.
library;

import 'snapshot_decoder.dart';
import 'snapshot_encode.dart';

export 'snapshot_decoder.dart' show SnapshotDecoder;
export 'snapshot_encode.dart' show VtTerminalSnapshot;
export 'snapshot_progress.dart'
    show
        SnapshotImagePixels,
        SnapshotPage,
        SnapshotProgress,
        UnknownSnapshotProgress;
