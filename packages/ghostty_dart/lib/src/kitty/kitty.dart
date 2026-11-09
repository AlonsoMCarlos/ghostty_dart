/// Kitty graphics protocol images and placements (`kitty_graphics.h`).
///
/// [VtTerminalKittyGraphics] reads a terminal's image storage: image
/// metadata ([KittyImage]), pixels, placements ([KittyPlacement]) and
/// animation playback. Image layers, protocols and placement kinds are the
/// render module's [ImageLayer], [ImageProtocol] and [KittyPlacementKind].
library;

import '../render/render_enums.dart';
import 'kitty_graphics.dart';
import 'kitty_types.dart';

export 'kitty_graphics.dart' show VtTerminalKittyGraphics;
export 'kitty_types.dart'
    show
        KittyImage,
        KittyImageCompression,
        KittyImageFormat,
        KittyPlacement,
        KittyPlacementGeometry;
