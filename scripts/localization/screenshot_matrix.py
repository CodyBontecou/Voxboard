#!/usr/bin/env python3
"""Plan, capture, audit, and contact-sheet the Vox.md localization matrix.

Capture refuses to boot simulators. Pass a UDID that is already Booted and a
stable story URL/state prepared by the operator or UI automation harness.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path


LOCALES = (
    "ar-SA", "de-DE", "en-US", "en-AU", "en-CA", "en-GB", "es-ES",
    "es-MX", "fr-FR", "fr-CA", "hi", "id", "it", "ja", "ko", "nl-NL",
    "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
)
LANGUAGE = {
    "ar-SA": "ar", "de-DE": "de", "en-US": "en", "en-AU": "en",
    "en-CA": "en", "en-GB": "en", "es-ES": "es", "es-MX": "es",
    "fr-FR": "fr", "fr-CA": "fr", "nl-NL": "nl", "pt-BR": "pt-BR",
}
STORIES = {
    "iphone": (
        "01-quick-capture", "02-live-recording", "03-settings", "04-models",
        "05-capture-presets", "06-privacy-local", "07-keyboard",
    ),
    "ipad": ("01-quick-capture", "02-history", "03-settings", "04-models", "05-live-recording"),
    "watch": ("01-ready", "02-recording", "03-synced"),
    "mac": ("01-capture", "02-history", "03-settings", "04-models", "05-presets"),
}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--root", type=Path, default=Path("artifacts/localization/screenshots"))
    capture = sub.add_parser("capture")
    capture.add_argument("--udid", required=True)
    capture.add_argument("--bundle-id", required=True)
    capture.add_argument("--locale", choices=LOCALES, required=True)
    capture.add_argument("--platform", choices=STORIES, required=True)
    capture.add_argument("--story", required=True)
    capture.add_argument("--root", type=Path, default=Path("artifacts/localization/screenshots"))
    capture.add_argument("--url")
    capture.add_argument("--wait", type=float, default=2.0)
    capture.add_argument("--ready-timeout", type=float, default=12.0)
    mac = sub.add_parser("capture-mac")
    mac.add_argument("--app", type=Path, required=True)
    mac.add_argument("--locale", choices=LOCALES, required=True)
    mac.add_argument("--story", required=True)
    mac.add_argument("--root", type=Path, default=Path("artifacts/localization/screenshots"))
    mac.add_argument("--timeout", type=float, default=15.0)
    audit = sub.add_parser("audit")
    audit.add_argument("--root", type=Path, default=Path("artifacts/localization/screenshots"))
    sheets = sub.add_parser("contact-sheets")
    sheets.add_argument("--root", type=Path, default=Path("artifacts/localization/screenshots"))
    return root


def resolved(root: Path) -> Path:
    repo = Path(__file__).resolve().parents[2]
    return root if root.is_absolute() else repo / root


def shot_path(root: Path, locale: str, platform: str, story: str) -> Path:
    return root / "raw" / locale / platform / f"{story}.png"


def plan(root: Path) -> int:
    root = resolved(root)
    entries = []
    for locale in LOCALES:
        for platform, stories in STORIES.items():
            for story in stories:
                entries.append(
                    {
                        "locale": locale,
                        "language": LANGUAGE.get(locale, locale),
                        "appleLocale": locale.replace("-", "_"),
                        "platform": platform,
                        "story": story,
                        "path": str(shot_path(root, locale, platform, story)),
                        "rtl": locale == "ar-SA",
                    }
                )
    root.mkdir(parents=True, exist_ok=True)
    manifest = root / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "locales": list(LOCALES),
                "counts": {platform: len(stories) for platform, stories in STORIES.items()},
                "expectedTotal": len(entries),
                "forcedLanguageArguments": ["-AppleLanguages", "(<language>)", "-AppleLocale", "<locale>"],
                "entries": entries,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Planned {len(entries)} screenshots at {manifest}")
    return 0


def simulator_state(udid: str) -> str | None:
    payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    for devices in payload.get("devices", {}).values():
        for device in devices:
            if device.get("udid") == udid:
                return device.get("state")
    return None


def image_is_near_blank(path: Path) -> bool:
    try:
        from PIL import Image
    except ImportError:
        return False
    image = Image.open(path).convert("L").resize((128, 128))
    histogram = image.histogram()
    near_white_fraction = sum(histogram[250:]) / sum(histogram)
    return image.entropy() < 0.5 and near_white_fraction > 0.95


def capture(args: argparse.Namespace) -> int:
    if args.story not in STORIES[args.platform]:
        raise SystemExit(f"Unknown {args.platform} story: {args.story}")
    state = simulator_state(args.udid)
    if state != "Booted":
        raise SystemExit(f"Refusing to boot simulator {args.udid}; current state is {state or 'unknown'}")
    language = LANGUAGE.get(args.locale, args.locale)
    subprocess.run(
        [
            "xcrun", "simctl", "launch", "--terminate-running-process", args.udid,
            args.bundle_id, "-AppleLanguages", f"({language})", "-AppleLocale",
            args.locale.replace("-", "_"), "--disable-release-notes",
            "--localization-screenshot", args.story,
        ],
        check=True,
    )
    if args.url:
        subprocess.run(["xcrun", "simctl", "openurl", args.udid, args.url], check=True)
    destination = shot_path(resolved(args.root), args.locale, args.platform, args.story)
    destination.parent.mkdir(parents=True, exist_ok=True)
    time.sleep(max(args.wait, 0))
    deadline = time.monotonic() + max(args.ready_timeout, 0)
    while True:
        subprocess.run(["xcrun", "simctl", "io", args.udid, "screenshot", str(destination)], check=True)
        if not image_is_near_blank(destination):
            break
        if time.monotonic() >= deadline:
            raise SystemExit(f"Timed out waiting for rendered screenshot: {destination}")
        time.sleep(0.5)
    print(destination)
    return 0


def capture_mac(args: argparse.Namespace) -> int:
    if args.story not in STORIES["mac"]:
        raise SystemExit(f"Unknown mac story: {args.story}")
    app = args.app.resolve()
    executable = app / "Contents" / "MacOS" / "Vox.md"
    if not executable.is_file():
        raise SystemExit(f"Mac executable is missing: {executable}")
    destination = shot_path(resolved(args.root), args.locale, "mac", args.story)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.unlink(missing_ok=True)
    language = LANGUAGE.get(args.locale, args.locale)
    process = subprocess.Popen(
        [
            str(executable), "-AppleLanguages", f"({language})", "-AppleLocale",
            args.locale.replace("-", "_"), "--disable-release-notes",
            "--localization-screenshot", args.story,
            "--localization-screenshot-output", str(destination),
        ]
    )
    deadline = time.monotonic() + max(args.timeout, 0)
    try:
        while time.monotonic() < deadline:
            if destination.exists() and destination.stat().st_size > 0:
                print(destination)
                return 0
            if process.poll() is not None:
                raise SystemExit(f"Mac app exited before capture (status {process.returncode})")
            time.sleep(0.1)
        raise SystemExit(f"Timed out waiting for Mac screenshot: {destination}")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def audit(root: Path) -> int:
    root = resolved(root)
    missing = []
    near_blank = []
    hashes: dict[tuple[str, str], dict[str, list[str]]] = {}
    for locale in LOCALES:
        for platform, stories in STORIES.items():
            key = (locale, platform)
            hashes[key] = {}
            for story in stories:
                path = shot_path(root, locale, platform, story)
                if not path.exists():
                    missing.append(str(path))
                    continue
                if image_is_near_blank(path):
                    near_blank.append(str(path))
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                hashes[key].setdefault(digest, []).append(story)
    duplicates = [
        {"locale": locale, "platform": platform, "stories": stories}
        for (locale, platform), groups in hashes.items()
        for stories in groups.values()
        if len(stories) > 1
    ]
    result = {
        "expected": 500,
        "missing": missing,
        "nearBlank": near_blank,
        "duplicateStoryGroups": duplicates,
    }
    report = root / "audit.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        f"missing={len(missing)} near_blank={len(near_blank)} "
        f"duplicate_story_groups={len(duplicates)} report={report}"
    )
    return 1 if missing or near_blank or duplicates else 0


def contact_sheets(root: Path) -> int:
    try:
        from PIL import Image, ImageDraw
    except ImportError as error:
        raise SystemExit("Pillow is required; use the bundled workspace Python runtime") from error
    root = resolved(root)
    created = 0
    for locale in LOCALES:
        for platform, stories in STORIES.items():
            paths = [shot_path(root, locale, platform, story) for story in stories]
            if not all(path.exists() for path in paths):
                continue
            images = [Image.open(path).convert("RGB") for path in paths]
            thumb_width = 320
            thumbs = [image.resize((thumb_width, round(image.height * thumb_width / image.width))) for image in images]
            cell_height = max(image.height for image in thumbs) + 48
            columns = min(4, len(thumbs))
            rows = (len(thumbs) + columns - 1) // columns
            sheet = Image.new("RGB", (columns * thumb_width, rows * cell_height), "white")
            draw = ImageDraw.Draw(sheet)
            for index, (story, image) in enumerate(zip(stories, thumbs)):
                x = (index % columns) * thumb_width
                y = (index // columns) * cell_height
                sheet.paste(image, (x, y))
                draw.text((x + 8, y + image.height + 8), f"{locale} · {story}", fill="black")
            destination = root / "contact-sheets" / locale / f"{platform}.jpg"
            destination.parent.mkdir(parents=True, exist_ok=True)
            sheet.save(destination, quality=88)
            created += 1
    print(f"Created {created}/100 contact sheets")
    return 0 if created == 100 else 1


def main() -> int:
    args = parser().parse_args()
    if args.command == "plan":
        return plan(args.root)
    if args.command == "capture":
        return capture(args)
    if args.command == "capture-mac":
        return capture_mac(args)
    if args.command == "audit":
        return audit(args.root)
    return contact_sheets(args.root)


if __name__ == "__main__":
    raise SystemExit(main())
