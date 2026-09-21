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

# Keep the on-device PDF and legacy-DOC parsers that release R8 would
# otherwise shrink until import looks like a damaged file.
-keep class com.tom_roush.** { *; }
-keep class org.apache.poi.hwpf.** { *; }

# SIKE loads tables relative to these class objects via getResourceAsStream.
# Preserve the class objects as well as their names; name-only rules still
# allow class-literal rewriting when a parameter class gets optimized away.
-keep class org.bouncycastle.pqc.crypto.sike.P434
-keep class org.bouncycastle.pqc.crypto.sike.P503
-keep class org.bouncycastle.pqc.crypto.sike.P610
-keep class org.bouncycastle.pqc.crypto.sike.P751

# Excluding lowmc.properties is safe only while its readers stay unreachable.
-checkdiscard class org.bouncycastle.pqc.crypto.picnic.LowmcConstants
-checkdiscard class org.bouncycastle.pqc.crypto.picnic.PicnicEngine

