import argparse
import json
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=pathlib.Path)
args = parser.parse_args()
records = []
for batch in ("international", "domestic", "followup", "final"):
    path = args.directory / batch / "report.json"
    if path.exists():
        for record in json.loads(path.read_text()):
            record["batch"] = batch
            record["platform"] = record["site"].split("-")[0]
            record["requestedQuality"] = record.get("requestedQuality", 480 if record["mode"] == "video" else None)
            if "mediaProbe" in record:
                record["probe"] = json.loads(record["mediaProbe"])
            records.append(record)
platforms = sorted({record["platform"] for record in records})
passed = [record for record in records if record["status"] == "passed"]
passed_platforms = sorted({record["platform"] for record in passed})
summary = {
    "engine": "StreamDrop DownloadEngine.swift (same source as installed application)",
    "authentication": "No cookies or account credentials supplied",
    "validation": "Full download, ffprobe, full FFmpeg decode with -xerror",
    "platform_count": len(platforms),
    "platforms_with_verified_download": passed_platforms,
    "attempt_count": len(records),
    "verified_file_count": len(passed),
    "verified_file_bytes": sum(record["bytes"] for record in passed),
    "attempts": records,
}
(args.directory / "all-results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print(f"PLATFORMS_WITH_VERIFIED_DOWNLOAD={len(passed_platforms)}/{len(platforms)}")
print(f"ATTEMPTS={len(records)}")
print(f"FILES_FULLY_DOWNLOADED_AND_DECODED={len(passed)}")
print(f"VERIFIED_FILE_BYTES={summary['verified_file_bytes']}")
print("SITE\tRESULT\tVIDEO_DIMENSIONS\tBYTES\tNOTE")
for platform in platforms:
    attempts = [record for record in records if record["platform"] == platform]
    successes = [record for record in attempts if record["status"] == "passed"]
    dimensions = []
    for record in successes:
        for stream in record.get("probe", {}).get("streams", []):
            if stream.get("codec_type") == "video":
                dimensions.append(f"{stream['width']}x{stream['height']}")
    errors = list(dict.fromkeys(record["error"] for record in attempts if record.get("error")))
    print(platform, "PASS" if successes else "NOT_VERIFIED", ",".join(dict.fromkeys(dimensions)) or "-", sum(record.get("bytes", 0) for record in successes), " | ".join(errors), sep="\t")
