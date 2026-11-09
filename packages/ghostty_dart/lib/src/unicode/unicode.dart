/// Unicode width and grapheme utilities that measure text exactly as the
/// terminal lays it out (`unicode.h`). No terminal is needed.
library;

export 'width.dart'
    show
        GraphemeCluster,
        codepointCellWidth,
        firstGraphemeCellWidth,
        graphemeClusters,
        textCellWidth;
