/// Ghostty's colour rules without a terminal: parsing colour strings the way
/// its config and theme files do, X11 colour names, the default and
/// generated 256-colour palettes, and luminance and contrast (`color.h`).
///
/// The colour value types themselves ([RgbColor], [ColorRef], ...) are core
/// types shared by every module.
library;

import '../core/core.dart';

export 'color_palette.dart'
    show RgbColorMetrics, defaultColorPalette, generateColorPalette;
export 'color_parse.dart'
    show
        parseColor,
        parsePaletteEntry,
        parseX11Color,
        tryParseColor,
        tryParsePaletteEntry,
        tryParseX11Color,
        x11ColorNames;
