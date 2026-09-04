# Project-specific R8 rules.
#
# Apache POI exposes optional desktop-only debug/rendering signatures that are
# not reached by ReadVibe's HWPF text extractor and do not exist on Android.
# Its logger also carries optional static-analysis annotations. Let R8 remove
# those unused paths while retaining the actual binary-DOC parser.
-dontwarn edu.umd.cs.findbugs.annotations.Nullable
-dontwarn edu.umd.cs.findbugs.annotations.SuppressFBWarnings
-dontwarn java.awt.Color
-dontwarn java.awt.Dimension
-dontwarn java.awt.Rectangle
-dontwarn java.awt.color.ColorSpace
-dontwarn java.awt.geom.AffineTransform
-dontwarn java.awt.geom.Dimension2D
-dontwarn java.awt.geom.Path2D
-dontwarn java.awt.geom.PathIterator
-dontwarn java.awt.geom.Point2D
-dontwarn java.awt.geom.Rectangle2D
-dontwarn java.awt.image.BufferedImage
-dontwarn java.awt.image.ColorModel
-dontwarn java.awt.image.ComponentColorModel
-dontwarn java.awt.image.DirectColorModel
-dontwarn java.awt.image.IndexColorModel
-dontwarn java.awt.image.PackedColorModel

# PDFBox-Android optionally decodes uncommon JPEG-2000 images through
# JP2Android. ReadVibe does not bundle that JCenter-only optional decoder;
# PDFBox deliberately ignores JPX images when it is absent.
-dontwarn com.gemalto.jp2.JP2Decoder
-dontwarn com.gemalto.jp2.JP2Encoder
