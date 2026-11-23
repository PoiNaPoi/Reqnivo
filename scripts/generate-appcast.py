#!/usr/bin/env python3
"""Generate or update a Sparkle appcast.xml from release metadata and a signed ZIP."""
from __future__ import annotations

import argparse
import email.utils
import json
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def parse_existing_items(appcast_path: Path) -> tuple[list[ET.Element], int, int | None]:
    if not appcast_path or not appcast_path.exists():
        return [], 0, None
    tree = ET.parse(appcast_path)
    channel = tree.find("channel")
    if channel is None:
        return [], 0, None
    items = channel.findall("item")
    max_build = 0
    max_threshold: int | None = None
    for item in items:
        ver_el = item.find(f"{{{SPARKLE_NS}}}version")
        if ver_el is not None and ver_el.text and ver_el.text.strip().isdigit():
            max_build = max(max_build, int(ver_el.text.strip()))
        crit_el = item.find(f"{{{SPARKLE_NS}}}criticalUpdate")
        if crit_el is not None:
            crit_ver = crit_el.attrib.get(f"{{{SPARKLE_NS}}}version")
            if crit_ver and crit_ver.strip().isdigit():
                val = int(crit_ver.strip())
                max_threshold = val if max_threshold is None else max(max_threshold, val)
            elif ver_el is not None and ver_el.text and ver_el.text.strip().isdigit():
                val = int(ver_el.text.strip())
                max_threshold = val if max_threshold is None else max(max_threshold, val)
    return items, max_build, max_threshold


def resolve_threshold(policy: dict, build: int, previous_threshold: int | None) -> int | None:
    mode = policy.get("updateMode")
    if mode not in ("optional", "force"):
        raise SystemExit(f"Invalid updateMode in release-policy.json: {mode!r}")

    raw_min = policy.get("minimumSupportedBuild")
    if raw_min is not None:
        if not isinstance(raw_min, int) or raw_min <= 0:
            raise SystemExit(f"minimumSupportedBuild must be a positive integer or null, got {raw_min!r}")
        if raw_min > build:
            raise SystemExit(f"minimumSupportedBuild ({raw_min}) cannot exceed package build ({build})")

    if mode == "force":
        candidate = raw_min if raw_min is not None else build
        return candidate if previous_threshold is None else max(candidate, previous_threshold)

    # Optional release: preserve any existing force threshold (or explicit lower threshold).
    if raw_min is not None:
        return raw_min if previous_threshold is None else max(raw_min, previous_threshold)
    return previous_threshold


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString (e.g. 0.0.7)")
    parser.add_argument("--build", required=True, type=int, help="CFBundleVersion integer")
    parser.add_argument("--zip-path", required=True, type=Path, help="Path to release ZIP archive")
    parser.add_argument("--download-url", required=True, help="Public HTTPS URL of the ZIP asset")
    parser.add_argument("--ed-signature", required=True, help="Sparkle Ed25519 signature of the ZIP")
    parser.add_argument("--policy-file", required=True, type=Path, help="Path to release-policy.json")
    parser.add_argument("--notes-file", type=Path, help="Optional release notes markdown/text file")
    parser.add_argument("--existing-appcast", type=Path, help="Optional existing appcast.xml to preserve history")
    parser.add_argument("--output", required=True, type=Path, help="Output appcast.xml path")
    parser.add_argument("--max-items", type=int, default=5, help="Max items to retain in appcast")
    args = parser.parse_args()

    if args.build <= 0:
        raise SystemExit(f"Build number must be positive, got {args.build}")
    if not args.zip_path.is_file():
        raise SystemExit(f"ZIP archive not found: {args.zip_path}")

    policy = json.loads(args.policy_file.read_text(encoding="utf-8"))
    existing_items, max_existing_build, previous_threshold = parse_existing_items(args.existing_appcast)
    if max_existing_build >= args.build:
        raise SystemExit(
            f"Build number {args.build} must be greater than existing highest appcast build {max_existing_build}"
        )

    threshold = resolve_threshold(policy, args.build, previous_threshold)
    notes_text = ""
    if args.notes_file and args.notes_file.is_file():
        notes_text = args.notes_file.read_text(encoding="utf-8").strip()

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Reqnivo Updates"

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Reqnivo {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(args.build)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}hardwareRequirements").text = "arm64"
    if threshold is not None:
        ET.SubElement(item, f"{{{SPARKLE_NS}}}criticalUpdate", {f"{{{SPARKLE_NS}}}version": str(threshold)})
    if notes_text:
        desc = ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "plain-text"})
        desc.text = notes_text
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.download_url,
            "length": str(args.zip_path.stat().st_size),
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": args.ed_signature.strip(),
        },
    )

    for old_item in existing_items[: max(0, args.max_items - 1)]:
        channel.append(old_item)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(rss, space="  ")
    args.output.write_bytes(ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n")
    print(f"Generated {args.output} (version={args.version}, build={args.build}, criticalThreshold={threshold})")


if __name__ == "__main__":
    main()
