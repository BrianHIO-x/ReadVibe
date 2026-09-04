"""Validate the release artifact without changing the APK."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


def digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(65536), b""):
        value.update(chunk)
    return value.hexdigest()


def inspect(apk, mapping, font, max_bytes):
    size = apk.stat().st_size
    if size > max_bytes:
        raise ValueError(f"APK size {size:,} exceeds budget {max_bytes:,}")
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
            r"org/bouncycastle/pqc/crypto/(picnic|sike)/.*\.properties$", name)]
        if unwanted:
            raise ValueError(f"Unused algorithm data is packaged: {unwanted}")
        bundled_font = "assets/flutter_assets/assets/fonts/SourceHanSerifSC-Regular.ttf"
        with font.open("rb") as source, archive.open(bundled_font) as packaged:
            if digest(source) != digest(packaged):
                raise ValueError("Bundled font differs from the complete source font")
        top_entries = sorted(archive.infolist(), key=lambda item: item.compress_size, reverse=True)[:6]
        largest = [{"path": item.filename, "compressed_bytes": item.compress_size} for item in top_entries]
    mapping_text = mapping.read_text(encoding="utf-8")
    if re.search(r"^org\.bouncycastle\.pqc\.crypto\.(picnic|sike)\.", mapping_text, re.MULTILINE):
        raise ValueError("An excluded algorithm became reachable; review its resources before releasing")
    return {"apk_bytes": size, "size_budget_bytes": max_bytes, "largest_entries": largest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--mapping", type=Path, required=True)
    parser.add_argument("--font", type=Path, default=Path("assets/fonts/SourceHanSerifSC-Regular.ttf"))
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--max-bytes", type=int, default=57_000_000)
    args = parser.parse_args()
    report = inspect(args.apk, args.mapping, args.font, args.max_bytes)
    if args.baseline:
        baseline = args.baseline.stat().st_size
        report.update(baseline_bytes=baseline, saved_bytes=baseline - report["apk_bytes"],
                      reduction_percent=round(100 * (baseline - report["apk_bytes"]) / baseline, 2))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
