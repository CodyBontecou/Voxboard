#!/usr/bin/env python3
"""Prepare supported-locale ASC metadata drafts without mutating ASC or Fastlane input."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

from complete_runtime_catalogs import (
    TranslationTask,
    mask_text,
    restore_text,
    translate_batch,
    translate_with_token_safe_fallback,
)
from metadata_reviewed_overrides import IAP_REVIEWED, METADATA_REVIEWED


ASC_LOCALES = (
    "ar-SA", "de-DE", "en-US", "en-AU", "en-CA", "en-GB", "es-ES",
    "es-MX", "fr-FR", "fr-CA", "hi", "id", "it", "ja", "ko", "nl-NL",
    "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
)
MODEL_LANGUAGE = {
    "ar-SA": "ar", "de-DE": "de", "es-ES": "es", "es-MX": "es",
    "fr-FR": "fr", "fr-CA": "fr", "nl-NL": "nl", "pt-BR": "pt",
    "zh-Hans": "zh",
}
ENGLISH_LOCALES = {"en-US", "en-AU", "en-CA", "en-GB"}
SUBTITLES = {
    "ar-SA": "التقط أي شيء إلى Markdown",
    "de-DE": "Alles in Markdown erfassen",
    "en-US": "Capture Anything to Markdown",
    "en-AU": "Capture Anything to Markdown",
    "en-CA": "Capture Anything to Markdown",
    "en-GB": "Capture Anything to Markdown",
    "es-ES": "Captura todo en Markdown",
    "es-MX": "Captura todo en Markdown",
    "fr-FR": "Tout capturer en Markdown",
    "fr-CA": "Tout capturer en Markdown",
    "hi": "Markdown में सब कैप्चर करें",
    "id": "Tangkap apa pun ke Markdown",
    "it": "Cattura tutto in Markdown",
    "ja": "何でもMarkdownにキャプチャ",
    "ko": "무엇이든 Markdown으로 캡처",
    "nl-NL": "Leg alles vast in Markdown",
    "pl": "Zapisuj wszystko w Markdown",
    "pt-BR": "Capture tudo em Markdown",
    "ru": "Сохраняйте всё в Markdown",
    "th": "บันทึกทุกอย่างเป็น Markdown",
    "tr": "Her şeyi Markdown'a kaydet",
    "uk": "Зберігайте все в Markdown",
    "vi": "Ghi mọi thứ vào Markdown",
    "zh-Hans": "将一切采集到 Markdown",
    "zh-Hant": "將一切擷取至 Markdown",
}
IAP_SOURCE = {
    "bontecou.Voxboard.unlock": {
        "displayName": "Vox.md Individual Unlimited",
        "description": "Unlimited Capture and transcription",
    },
    "bontecou.Voxboard.family": {
        "displayName": "Vox.md Family Unlimited",
        "description": "Unlimited access with Family Sharing",
    },
    "bontecou.Voxboard.familyUpgrade": {
        "displayName": "Vox.md Family Upgrade",
        "description": "Add Family Sharing to Unlimited",
    },
}
PROMOTIONAL_TEXT_SOURCE = (
    "Capture text, links, files, images, scans, sketches, and voice to Markdown. "
    "Transcription stays on device."
)
IAP_OVERRIDES = IAP_REVIEWED


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="facebook/m2m100_1.2B")
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    parser.add_argument("--output", type=Path, default=Path("artifacts/localization/metadata-proposal"))
    parser.add_argument(
        "--reviewed-only",
        action="store_true",
        help="Apply deterministic reviewed metadata without loading the translation model.",
    )
    return parser.parse_args()


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value.rstrip() + "\n", encoding="utf-8")


def validate_metadata(locale: str, directory: Path) -> list[str]:
    issues: list[str] = []
    limits = {"name.txt": 30, "subtitle.txt": 30, "promotional_text.txt": 170, "description.txt": 4000}
    for filename, limit in limits.items():
        path = directory / filename
        if path.exists() and len(path.read_text(encoding="utf-8").rstrip()) > limit:
            issues.append(f"{locale}/{filename} exceeds {limit} characters")
    keywords = directory / "keywords.txt"
    if keywords.exists() and len(keywords.read_text(encoding="utf-8").strip().encode("utf-8")) > 100:
        issues.append(f"{locale}/keywords.txt exceeds 100 UTF-8 bytes")
    return issues


def trim_keywords(value: str, maximum_bytes: int = 100) -> str:
    kept: list[str] = []
    for keyword in (item.strip() for item in value.split(",")):
        candidate = ",".join((*kept, keyword))
        if len(candidate.encode("utf-8")) > maximum_bytes:
            continue
        kept.append(keyword)
    return ",".join(kept)


def translate_values(
    tokenizer: M2M100Tokenizer,
    model: M2M100ForConditionalGeneration,
    values: list[str],
    locale: str,
    device: str,
) -> list[str]:
    plans = [re.split(r"(\n+)", value) for value in values]
    placements: list[tuple[int, int, TranslationTask]] = []
    masked_values = []
    for plan_index, plan in enumerate(plans):
        for piece_index, piece in enumerate(plan):
            if not piece.strip() or piece.startswith("\n"):
                continue
            task = TranslationTask(0, f"{plan_index}:{piece_index}", piece)
            placements.append((plan_index, piece_index, task))
            masked_values.append(mask_text(piece))

    order = sorted(range(len(masked_values)), key=lambda index: len(masked_values[index].value))
    translated = [""] * len(masked_values)
    for start in range(0, len(order), 16):
        indices = order[start : start + 16]
        outputs = translate_batch(
            tokenizer,
            model,
            [masked_values[index].value for index in indices],
            locale,
            device,
            1,
        )
        for index, output in zip(indices, outputs):
            try:
                translated[index] = restore_text(output, masked_values[index])
            except ValueError:
                translated[index] = translate_with_token_safe_fallback(
                    tokenizer, model, placements[index][2], masked_values[index], locale, device, 1
                )

    for index, (plan_index, piece_index, _) in enumerate(placements):
        plans[plan_index][piece_index] = translated[index]
    return ["".join(plan) for plan in plans]


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output if args.output.is_absolute() else root / args.output
    source_root = root / "fastlane/metadata"
    output.mkdir(parents=True, exist_ok=True)

    if args.reviewed_only:
        for locale, fields_for_locale in METADATA_REVIEWED.items():
            destination = output / "fastlane" / locale
            for field, value in fields_for_locale.items():
                write_text(destination / field, value)

        iap_path = output / "iap-localizations.json"
        iap_localizations = json.loads(iap_path.read_text(encoding="utf-8"))
        for locale, products_for_locale in IAP_REVIEWED.items():
            iap_localizations[locale] = products_for_locale

        issues: list[str] = []
        for locale, products_for_locale in iap_localizations.items():
            for product_id, fields in products_for_locale.items():
                if len(fields["displayName"]) > 30:
                    issues.append(f"{locale}/{product_id} displayName exceeds 30 characters")
                if len(fields["description"]) > 45:
                    issues.append(f"{locale}/{product_id} description exceeds 45 characters")
        for locale in ASC_LOCALES:
            issues.extend(validate_metadata(locale, output / "fastlane" / locale))

        iap_path.write_text(
            json.dumps(iap_localizations, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (output / "validation.json").write_text(
            json.dumps({"issues": issues}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Reviewed metadata locales: {len(METADATA_REVIEWED)}", flush=True)
        print(f"Reviewed IAP locales: {len(IAP_REVIEWED)}", flush=True)
        print(f"Validation issues: {len(issues)}", flush=True)
        return 1 if issues else 0

    import torch
    from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer

    device = args.device
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    tokenizer = M2M100Tokenizer.from_pretrained(args.model, local_files_only=True)
    model = M2M100ForConditionalGeneration.from_pretrained(args.model, local_files_only=True).to(device).eval()

    source_fields = {
        field: (source_root / "en-US" / field).read_text(encoding="utf-8").rstrip()
        for field in ("description.txt", "release_notes.txt", "promotional_text.txt")
    }
    source_fields["promotional_text.txt"] = PROMOTIONAL_TEXT_SOURCE
    all_issues: list[str] = []
    iap_localizations: dict[str, dict] = {}

    for locale in ASC_LOCALES:
        destination = output / "fastlane" / locale
        destination.mkdir(parents=True, exist_ok=True)
        existing = source_root / locale
        for path in existing.glob("*.txt"):
            shutil.copy2(path, destination / path.name)
        keywords_path = destination / "keywords.txt"
        if keywords_path.exists():
            write_text(keywords_path, trim_keywords(keywords_path.read_text(encoding="utf-8").strip()))

        write_text(destination / "name.txt", (source_root / "en-US/name.txt").read_text(encoding="utf-8") if locale in ENGLISH_LOCALES else "Vox.md")
        write_text(destination / "subtitle.txt", SUBTITLES[locale])

        if locale in ENGLISH_LOCALES:
            translated_fields = source_fields
            translated_iap = IAP_SOURCE
        elif locale == "zh-Hant":
            from opencc import OpenCC

            converter = OpenCC("s2tw")
            translated_fields = {
                field: converter.convert(
                    (output / "fastlane" / "zh-Hans" / field).read_text(encoding="utf-8").rstrip()
                )
                for field in source_fields
            }
            translated_iap = {
                product_id: {field: converter.convert(value) for field, value in fields.items()}
                for product_id, fields in iap_localizations["zh-Hans"].items()
            }
        else:
            model_locale = MODEL_LANGUAGE.get(locale, locale)
            field_values = translate_values(
                tokenizer, model, list(source_fields.values()), model_locale, device
            )
            translated_fields = dict(zip(source_fields, field_values))

            iap_keys: list[tuple[str, str]] = []
            iap_sources: list[str] = []
            for product_id, fields in IAP_SOURCE.items():
                for field, value in fields.items():
                    iap_keys.append((product_id, field))
                    iap_sources.append(value)
            iap_values = translate_values(
                tokenizer, model, iap_sources, model_locale, device
            )
            translated_iap = {product_id: {} for product_id in IAP_SOURCE}
            for (product_id, field), value in zip(iap_keys, iap_values):
                translated_iap[product_id][field] = value

        translated_fields.update(METADATA_REVIEWED.get(locale, {}))

        for product_id, fields in IAP_OVERRIDES.get(locale, {}).items():
            translated_iap[product_id].update(fields)

        for field, value in translated_fields.items():
            write_text(destination / field, value)
        all_issues.extend(validate_metadata(locale, destination))
        iap_localizations[locale] = translated_iap
        print(f"{locale}: prepared", flush=True)
        if device == "mps":
            torch.mps.empty_cache()

    for locale, products in iap_localizations.items():
        for product_id, fields in products.items():
            if len(fields["displayName"]) > 30:
                all_issues.append(f"{locale}/{product_id} displayName exceeds 30 characters")
            if len(fields["description"]) > 45:
                all_issues.append(f"{locale}/{product_id} description exceeds 45 characters")

    (output / "iap-localizations.json").write_text(
        json.dumps(iap_localizations, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output / "validation.json").write_text(
        json.dumps({"issues": all_issues}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Validation issues: {len(all_issues)}", flush=True)
    return 1 if all_issues else 0


if __name__ == "__main__":
    raise SystemExit(main())
