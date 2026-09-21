"""Validate the release artifact without changing the APK."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile


SIKE_PACKAGE = "org.bouncycastle.pqc.crypto.sike"
SIKE_TABLES = ("434", "503", "610", "751")
# These key/parameter containers do not load lowmc.properties. Any other
# surviving Picnic code, including code inlined into another class, needs review.
PICNIC_METADATA = {
    "PicnicParameters", "PicnicKeyParameters",
    "PicnicPrivateKeyParameters", "PicnicPublicKeyParameters",
}
# Includes the roughly 2.6 MB of compressed SIKE tables needed by PDFBox's
# retained key parameter initialization, with less than 1 MB of headroom.
RELEASE_SIZE_BUDGET = 60_000_000


def digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(65536), b""):
        value.update(chunk)
    return value.hexdigest()


def dex_class_descriptors(data):
    """Read defined classes, not just names referenced by another DEX class."""
    if len(data) < 112 or data[:4] != b"dex\n":
        raise ValueError("Invalid DEX header")
    if struct.unpack_from("<I", data, 40)[0] != 0x12345678:
        raise ValueError("Unsupported DEX byte order")
    string_count, strings = struct.unpack_from("<II", data, 56)
    type_count, types = struct.unpack_from("<II", data, 64)
    class_count, classes = struct.unpack_from("<II", data, 96)
    if (strings + 4 * string_count > len(data)
            or types + 4 * type_count > len(data)
            or classes + 32 * class_count > len(data)):
        raise ValueError("Invalid DEX table bounds")
    result = set()
    for index in range(class_count):
        type_index = struct.unpack_from("<I", data, classes + 32 * index)[0]
        if type_index >= type_count:
            raise ValueError("Invalid DEX class type")
        name_index = struct.unpack_from("<I", data, types + 4 * type_index)[0]
        if name_index >= string_count:
            raise ValueError("Invalid DEX class name")
        offset = struct.unpack_from("<I", data, strings + 4 * name_index)[0]
        # Each string starts with a ULEB128 UTF-16 length (at most five bytes).
        for _ in range(5):
            byte = data[offset]
            offset += 1
            if not byte & 0x80:
                break
        else:
            raise ValueError("Invalid DEX string length")
        end = data.index(b"\0", offset)
        result.add(data[offset:end])
    return result


def inspect(apk, mapping, font, max_bytes):
    size = apk.stat().st_size
    if size > max_bytes:
        raise ValueError(f"APK size {size:,} exceeds budget {max_bytes:,}")
    mapping_text = mapping.read_text(encoding="utf-8")
    picnic_types = set(re.findall(
        r"\borg\.bouncycastle\.pqc\.crypto\.picnic\.([A-Za-z0-9_$]+)",
        mapping_text))
    unsafe_picnic = sorted(picnic_types - PICNIC_METADATA)
    if unsafe_picnic:
        raise ValueError(f"Picnic code survives without its data table: {unsafe_picnic}")
    class_names = dict(re.findall(r"^(\S+) -> (\S+):$", mapping_text, re.MULTILINE))
    for table in SIKE_TABLES:
        loader = f"{SIKE_PACKAGE}.P{table}"
        # R8 may omit entirely unchanged classes from mapping.txt. Verify their
        # actual definitions in the APK below instead of treating omission as removal.
        if class_names.get(loader, loader) != loader:
            raise ValueError(f"SIKE resource loader was renamed: {loader}")
    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
        required = {
            "lib/arm64-v8a/libflutter.so",
            "lib/arm64-v8a/libapp.so",
            "lib/arm64-v8a/libmlkit_google_ocr_pipeline.so",
            "assets/flutter_assets/assets/fonts/SourceHanSerifSC-Regular.ttf",
        }
        missing = required - names
        if missing:
            raise ValueError(f"Required offline resources missing: {sorted(missing)}")
        abis = {name.split("/")[1] for name in names if name.startswith("lib/")}
        if abis != {"arm64-v8a"}:
            raise ValueError(f"Unexpected release ABIs: {sorted(abis)}")
        if not any("/Hani_ctc/" in name for name in names):
            raise ValueError("Bundled Chinese OCR model is missing")
        unwanted = [name for name in names if re.match(
            r"org/bouncycastle/pqc/crypto/picnic/.*\.properties$", name)]
        if unwanted:
            raise ValueError(f"Unused algorithm data is packaged: {unwanted}")
        defined_classes = set()
        for name in names:
            if re.fullmatch(r"classes(?:[0-9]+)?\.dex", name):
                defined_classes.update(dex_class_descriptors(archive.read(name)))
        sike_data_bytes = 0
        for table in SIKE_TABLES:
            descriptor = f"L{SIKE_PACKAGE.replace('.', '/')}/P{table};".encode("ascii")
            if descriptor not in defined_classes:
                raise ValueError(f"SIKE resource loader missing from APK: {descriptor!r}")
            resource = f"{SIKE_PACKAGE.replace('.', '/')}/p{table}.properties"
            if resource not in names:
                raise ValueError(f"Required SIKE data table missing: {resource}")
            if not archive.read(resource).strip():
                raise ValueError(f"Required SIKE data table is empty: {resource}")
            sike_data_bytes += archive.getinfo(resource).compress_size
        bundled_font = "assets/flutter_assets/assets/fonts/SourceHanSerifSC-Regular.ttf"
        with font.open("rb") as source, archive.open(bundled_font) as packaged:
            if digest(source) != digest(packaged):
                raise ValueError("Bundled font differs from the complete source font")
        top_entries = sorted(archive.infolist(), key=lambda item: item.compress_size, reverse=True)[:6]
        largest = [{"path": item.filename, "compressed_bytes": item.compress_size} for item in top_entries]
    return {"apk_bytes": size, "size_budget_bytes": max_bytes,
            "sike_data_compressed_bytes": sike_data_bytes, "largest_entries": largest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--mapping", type=Path, required=True)
    parser.add_argument("--font", type=Path, default=Path("assets/fonts/SourceHanSerifSC-Regular.ttf"))
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--max-bytes", type=int, default=RELEASE_SIZE_BUDGET)
    args = parser.parse_args()
    report = inspect(args.apk, args.mapping, args.font, args.max_bytes)
    if args.baseline:
        baseline = args.baseline.stat().st_size
        report.update(baseline_bytes=baseline, saved_bytes=baseline - report["apk_bytes"],
                      reduction_percent=round(100 * (baseline - report["apk_bytes"]) / baseline, 2))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
