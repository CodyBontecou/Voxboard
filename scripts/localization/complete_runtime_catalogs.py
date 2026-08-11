#!/usr/bin/env python3
"""Fill missing Vox.md String Catalog entries with offline M2M100 translations.

The script preserves reviewed translations and protects format placeholders,
Markdown/code tokens, product names, model names, file extensions, URLs, and
keyboard shortcuts. It checkpoints every completed locale so an interrupted
run can be resumed safely.

Runtime dependencies are intentionally external to the Xcode project:
  pip install torch transformers sentencepiece protobuf opencc-python-reimplemented
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from screenshot_reviewed_overrides import SCREENSHOT_REVIEWED_OVERRIDES


RUNTIME_LOCALES = (
    "ar",
    "bn",
    "de",
    "en",
    "es",
    "fr",
    "hi",
    "id",
    "it",
    "ja",
    "ko",
    "nl",
    "pl",
    "pt-BR",
    "ru",
    "ta",
    "th",
    "tr",
    "uk",
    "ur",
    "vi",
    "zh-Hans",
    "zh-Hant",
)

MODEL_LANGUAGE = {
    "pt-BR": "pt",
    "zh-Hans": "zh",
}

# Canonical base terms. These are applied when a catalog entry consists only
# of the glossary term; contextual sentences remain free to inflect naturally.
GLOSSARY = {
    "ar": ("التقاط", "نسخ صوتي", "تسجيل", "ملاحظات", "الحافظة", "ملحق لوحة المفاتيح", "وصول غير محدود", "المشاركة العائلية"),
    "bn": ("ক্যাপচার", "ট্রান্সক্রিপশন", "রেকর্ডিং", "নোট", "ক্লিপবোর্ড", "কীবোর্ড এক্সটেনশন", "আনলিমিটেড অ্যাক্সেস", "ফ্যামিলি শেয়ারিং"),
    "de": ("Erfassung", "Transkription", "Aufnahme", "Notizen", "Zwischenablage", "Tastaturerweiterung", "Unbegrenzter Zugriff", "Familienfreigabe"),
    "es": ("Captura", "Transcripción", "Grabación", "Notas", "Portapapeles", "Extensión de teclado", "Acceso ilimitado", "En familia"),
    "fr": ("Capture", "Transcription", "Enregistrement", "Notes", "Presse-papiers", "Extension de clavier", "Accès illimité", "Partage familial"),
    "hi": ("कैप्चर", "ट्रांसक्रिप्शन", "रिकॉर्डिंग", "नोट्स", "क्लिपबोर्ड", "कीबोर्ड एक्सटेंशन", "अनलिमिटेड ऐक्सेस", "फ़ैमिली शेयरिंग"),
    "id": ("Tangkapan", "Transkripsi", "Rekaman", "Catatan", "Papan Klip", "Ekstensi Papan Ketik", "Akses Tanpa Batas", "Keluarga Berbagi"),
    "it": ("Acquisizione", "Trascrizione", "Registrazione", "Note", "Appunti", "Estensione tastiera", "Accesso illimitato", "In famiglia"),
    "ja": ("キャプチャ", "文字起こし", "録音", "メモ", "クリップボード", "キーボード機能拡張", "無制限アクセス", "ファミリー共有"),
    "ko": ("캡처", "전사", "녹음", "메모", "클립보드", "키보드 확장 프로그램", "무제한 이용", "가족 공유"),
    "nl": ("Vastleggen", "Transcriptie", "Opname", "Notities", "Klembord", "Toetsenbordextensie", "Onbeperkte toegang", "Delen met gezin"),
    "pl": ("Przechwytywanie", "Transkrypcja", "Nagranie", "Notatki", "Schowek", "Rozszerzenie klawiatury", "Nieograniczony dostęp", "Chmura rodzinna"),
    "pt-BR": ("Captura", "Transcrição", "Gravação", "Notas", "Área de Transferência", "Extensão de Teclado", "Acesso Ilimitado", "Compartilhamento Familiar"),
    "ru": ("Захват", "Транскрипция", "Запись", "Заметки", "Буфер обмена", "Расширение клавиатуры", "Безлимитный доступ", "Семейный доступ"),
    "ta": ("பிடிப்பு", "உரைமாற்றம்", "பதிவு", "குறிப்புகள்", "கிளிப்போர்டு", "விசைப்பலகை நீட்டிப்பு", "வரம்பற்ற அணுகல்", "குடும்பப் பகிர்வு"),
    "th": ("การจับภาพ", "การถอดเสียง", "การบันทึก", "โน้ต", "คลิปบอร์ด", "ส่วนขยายแป้นพิมพ์", "การเข้าถึงไม่จำกัด", "การแชร์กันในครอบครัว"),
    "tr": ("Yakalama", "Transkripsiyon", "Kayıt", "Notlar", "Pano", "Klavye Uzantısı", "Sınırsız Erişim", "Aile Paylaşımı"),
    "uk": ("Захоплення", "Транскрипція", "Запис", "Нотатки", "Буфер обміну", "Розширення клавіатури", "Необмежений доступ", "Сімейний доступ"),
    "ur": ("کیپچر", "ٹرانسکرپشن", "ریکارڈنگ", "نوٹس", "کلپ بورڈ", "کی بورڈ ایکسٹینشن", "لامحدود رسائی", "فیملی شیئرنگ"),
    "vi": ("Ghi nhanh", "Bản chép lời", "Bản ghi âm", "Ghi chú", "Bảng nhớ tạm", "Tiện ích bàn phím", "Quyền truy cập không giới hạn", "Chia sẻ trong gia đình"),
    "zh-Hans": ("采集", "转录", "录音", "笔记", "剪贴板", "键盘扩展", "无限访问", "家人共享"),
    "zh-Hant": ("擷取", "轉錄", "錄音", "筆記", "剪貼簿", "鍵盤延伸功能", "無限存取權", "家人共享"),
}
GLOSSARY_SOURCES = (
    "Capture",
    "Transcription",
    "Recording",
    "Notes",
    "Clipboard",
    "Keyboard Extension",
    "Unlimited Access",
    "Family Sharing",
)

# Short fragments are the hardest inputs for statistical MT because words such
# as “capture” and “save” are ambiguous without UI context. Keep critical system
# labels deterministic and reviewed here.
CAPTURE_TO_VOX = {
    "ar": "إرسال إلى Vox.md",
    "bn": "Vox.md-এ ক্যাপচার করুন",
    "de": "In Vox.md erfassen",
    "es": "Capturar en Vox.md",
    "fr": "Capturer dans Vox.md",
    "hi": "Vox.md में कैप्चर करें",
    "id": "Simpan ke Vox.md",
    "it": "Acquisisci in Vox.md",
    "ja": "Vox.mdにキャプチャ",
    "ko": "Vox.md에 캡처",
    "nl": "Vastleggen in Vox.md",
    "pl": "Przechwyć do Vox.md",
    "pt-BR": "Capturar no Vox.md",
    "ru": "Сохранить в Vox.md",
    "ta": "Vox.md-க்குப் பிடிக்கவும்",
    "th": "บันทึกไปยัง Vox.md",
    "tr": "Vox.md'ye Kaydet",
    "uk": "Зберегти у Vox.md",
    "ur": "Vox.md میں کیپچر کریں",
    "vi": "Ghi vào Vox.md",
    "zh-Hans": "采集到 Vox.md",
    "zh-Hant": "擷取至 Vox.md",
}

MARKDOWN_NOTE = {
    "ar": "اختر ملاحظة Markdown (.md).",
    "bn": "একটি Markdown (.md) নোট বেছে নিন।",
    "de": "Wähle eine Markdown-Notiz (.md) aus.",
    "es": "Elige una nota Markdown (.md).",
    "fr": "Choisissez une note Markdown (.md).",
    "hi": "एक Markdown (.md) नोट चुनें।",
    "id": "Pilih catatan Markdown (.md).",
    "it": "Scegli una nota Markdown (.md).",
    "ja": "Markdown（.md）形式のノートを選択してください。",
    "ko": "Markdown(.md) 노트를 선택하세요.",
    "nl": "Kies een Markdown-notitie (.md).",
    "pl": "Wybierz notatkę Markdown (.md).",
    "pt-BR": "Escolha uma nota Markdown (.md).",
    "ru": "Выберите заметку Markdown (.md).",
    "ta": "Markdown (.md) குறிப்பைத் தேர்ந்தெடுக்கவும்.",
    "th": "เลือกโน้ต Markdown (.md)",
    "tr": "Bir Markdown (.md) notu seçin.",
    "uk": "Виберіть нотатку Markdown (.md).",
    "ur": "ایک Markdown (.md) نوٹ منتخب کریں۔",
    "vi": "Chọn một ghi chú Markdown (.md).",
    "zh-Hans": "选择一篇 Markdown（.md）笔记。",
    "zh-Hant": "選擇一則 Markdown（.md）筆記。",
}

MARKDOWN_TEMPLATE = {
    "ar": "اختر ملف قالب Markdown (.md).",
    "bn": "একটি Markdown (.md) টেমপ্লেট ফাইল বেছে নিন।",
    "de": "Wähle eine Markdown-Vorlagendatei (.md) aus.",
    "es": "Elige un archivo de plantilla Markdown (.md).",
    "fr": "Choisissez un fichier de modèle Markdown (.md).",
    "hi": "एक Markdown (.md) टेम्प्लेट फ़ाइल चुनें।",
    "id": "Pilih file templat Markdown (.md).",
    "it": "Scegli un file modello Markdown (.md).",
    "ja": "Markdown（.md）形式のテンプレートファイルを選択してください。",
    "ko": "Markdown(.md) 템플릿 파일을 선택하세요.",
    "nl": "Kies een Markdown-sjabloonbestand (.md).",
    "pl": "Wybierz plik szablonu Markdown (.md).",
    "pt-BR": "Escolha um arquivo de modelo Markdown (.md).",
    "ru": "Выберите файл шаблона Markdown (.md).",
    "ta": "Markdown (.md) வார்ப்புருக் கோப்பைத் தேர்ந்தெடுக்கவும்.",
    "th": "เลือกไฟล์เทมเพลต Markdown (.md)",
    "tr": "Bir Markdown (.md) şablon dosyası seçin.",
    "uk": "Виберіть файл шаблону Markdown (.md).",
    "ur": "ایک Markdown (.md) ٹیمپلیٹ فائل منتخب کریں۔",
    "vi": "Chọn một tệp mẫu Markdown (.md).",
    "zh-Hans": "选择一个 Markdown（.md）模板文件。",
    "zh-Hant": "選擇一個 Markdown（.md）範本檔案。",
}

REVIEWED_OVERRIDES = {
    "Choose a Markdown (.md) note.": MARKDOWN_NOTE,
    "Choose a Markdown (.md) template file.": MARKDOWN_TEMPLATE,
    "Copy Cleaned": {"ko": "정리된 내용 복사"},
    "Copy cleaned": {"ko": "정리된 내용 복사"},
    "Delete Preset": {"ko": "프리셋 삭제"},
    "Limit reached · Unlock": {"ko": "한도 도달 · 잠금 해제"},
    "Queue": {"ko": "대기열"},
    "Resume • Stop • Cancel": {"ko": "재개 • 중지 • 취소"},
    "Sent": {"ko": "전송됨"},
    "Use Preset Defaults": {"ko": "프리셋 기본값 사용"},
    "Enter a complete http:// or https:// link.": {
        "tr": "Tam bir http:// veya https:// bağlantısı girin."
    },
    "Discarded on iPhone": {"ar": "تم التجاهل على iPhone"},
    "Queued to retry on iPhone": {"ar": "في قائمة الانتظار لإعادة المحاولة على iPhone"},
    "Saved on Watch. Syncing to iPhone…": {
        "ar": "تم الحفظ على Watch. جارٍ المزامنة مع iPhone…"
    },
    "Saved on iPhone": {"ar": "تم الحفظ على iPhone"},
    "Saving the recording on iPhone.": {"ar": "جارٍ حفظ التسجيل على iPhone."},
    "No text was found in those journal images. Try brighter, straighter photos with the writing filling the frame.": {
        "ta": "அந்த நாட்குறிப்பு படங்களில் எந்த உரையும் காணப்படவில்லை. எழுத்து சட்டகத்தை நிரப்பும் வகையில், அதிக வெளிச்சத்துடன் நேராக எடுத்த படங்களை முயற்சிக்கவும்."
    },
    "The reserved filename belongs to another Files folder. Choose a recording-only preset to retarget it explicitly.": {
        "ta": "ஒதுக்கப்பட்ட கோப்புப்பெயர் மற்றொரு Files கோப்புறைக்குச் சொந்தமானது. அதை வெளிப்படையாக மாற்ற, பதிவு மட்டும் கொண்ட முன்தொகுப்பைத் தேர்ந்தெடுக்கவும்."
    },
    "This destination belongs to this preset. It includes the note target, placement, entry formatting, attachments folder, and retry behavior.": {
        "ta": "இந்த இலக்கு இந்த முன்தொகுப்புக்குச் சொந்தமானது. இதில் குறிப்பின் இலக்கு, இடமமைவு, பதிவு வடிவமைப்பு, இணைப்புகள் கோப்புறை மற்றும் மீண்டும் முயற்சிக்கும் நடத்தை ஆகியவை அடங்கும்."
    },
    "This destination stays linked to the reusable template. Choose Custom to edit a private snapshot.": {
        "ta": "இந்த இலக்கு மீண்டும் பயன்படுத்தக்கூடிய வார்ப்புருவுடன் இணைந்தே இருக்கும். தனிப்பட்ட நகலைத் திருத்த ‘தனிப்பயன்’ என்பதைத் தேர்ந்தெடுக்கவும்."
    },
    "This switch applies to typed and mixed-media Capture text. Voice recordings continue to use the preset’s selected mode.": {
        "ta": "இந்த மாற்றி தட்டச்சு செய்த மற்றும் கலப்பு ஊடகப் பிடிப்பு உரைக்கு பொருந்தும். குரல் பதிவுகள் முன்தொகுப்பில் தேர்ந்தெடுத்த பயன்முறையைத் தொடர்ந்து பயன்படுத்தும்."
    },
    "Watch recordings use this preset's normal on-device transcription and Capture destination workflow.": {
        "ta": "Watch பதிவுகள் இந்த முன்தொகுப்பின் வழக்கமான சாதனத்திலேயே நடைபெறும் உரைமாற்றம் மற்றும் பிடிப்பு இலக்கு பணிப்பாய்வைப் பயன்படுத்தும்."
    },
    "Record note": {"th": "บันทึกโน้ต"},
    "Recorded": {"th": "บันทึกแล้ว"},
    "Recordings": {"th": "รายการบันทึก"},
    "Saved": {"th": "บันทึกแล้ว"},
    "Audio Export Directory": {"de": "Audio-Exportordner"},
    "Keyboard Integration": {"de": "Tastaturintegration"},
    "Legacy Voice File Export": {
        "de": "Export älterer Sprachdateien",
        "nl": "Export van oudere spraakbestanden",
    },
    "In-App · Add to Draft": {"ja": "アプリ内 · 下書きに追加"},
    "Capture route %@, %@": {"nl": "Vastlegroute %@, %@"},
    "Clearer Watch upgrades": {"nl": "Duidelijkere Watch-upgrades"},
    "Optional optimized local models you can download and select explicitly.": {
        "ta": "நீங்கள் பதிவிறக்கம் செய்து வெளிப்படையாகத் தேர்ந்தெடுக்கக்கூடிய, மேம்படுத்தப்பட்ட விருப்ப உள்ளூர் மாதிரிகள்."
    },
    "Widgets & Quick Record": {"th": "วิดเจ็ตและการบันทึกด่วน"},
}

PROTECTED_TERMS = (
    "Vox.md",
    "whisper.cpp",
    "Whisper",
    "Parakeet",
    "Apple Speech",
    "Apple Intelligence",
    "Foundation Models",
    "FluidAudio",
    "CoreML",
    "Obsidian",
    "Markdown",
    "App Store",
    "Apple Watch",
    "iPhone",
    "iPad",
    "macOS",
    "watchOS",
    "iOS",
    "M4A",
    "WAV",
    "TXT",
    "JSON",
    "YAML",
    "SF Symbols",
    "Cmd-Tab",
    "ZenQuotes",
    "Slugify",
)

FORMAT_PATTERN = r"%(?:\d+\$)?[-+#0 ']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|L|z|j|t|q)?[@diuoxXfFeEgGaAcCsSpn]"
BRACE_PATTERN = r"\{[^{}\n]+\}"
URL_PATTERN = r"https?://[^\s<>]+"
WIKILINK_PATTERN = r"!?\[\[[^\]\n]+\]\]"
CODE_PATTERN = r"`[^`\n]+`"
FILE_EXTENSION_PATTERN = r"(?<![\w.])\.(?:md|m4a|wav|txt|json|ya?ml|voxsketch)\b"
SHORTCUT_PATTERN = r"(?:⌃|⌥|⌘|⇧)+[^\s,.;:]+|\bF(?:[1-9]|1[0-6])\b"
PROTECTED_PATTERN = re.compile(
    "|".join(
        (
            URL_PATTERN,
            WIKILINK_PATTERN,
            CODE_PATTERN,
            BRACE_PATTERN,
            FORMAT_PATTERN,
            FILE_EXTENSION_PATTERN,
            SHORTCUT_PATTERN,
            *(re.escape(term) for term in sorted(PROTECTED_TERMS, key=len, reverse=True)),
        )
    )
)
TOKEN_PATTERN = re.compile(
    r"Z\s*X+\s*Q(?:\s*X)?\s*(\d{3})\s*Q\s*X+\s*Z?",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class TranslationTask:
    catalog_index: int
    key: str
    source: str


@dataclass(frozen=True)
class MaskedText:
    value: str
    replacements: tuple[str, ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--catalog",
        action="append",
        dest="catalogs",
        type=Path,
        help="Catalog to update. Repeatable; defaults to every shipped catalog.",
    )
    parser.add_argument("--model", default="facebook/m2m100_1.2B")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--beams", type=int, default=4)
    parser.add_argument("--locales", nargs="*", default=list(RUNTIME_LOCALES))
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    parser.add_argument("--overwrite", action="store_true", help="Replace existing reviewed translations.")
    parser.add_argument("--overrides-only", action="store_true", help="Apply deterministic reviewed overrides without loading the model.")
    return parser.parse_args()


def default_catalogs(root: Path) -> list[Path]:
    return [
        root / "Voxboard/Localizable.xcstrings",
        root / "Voxboard Keyboard/Localizable.xcstrings",
        root / "Voxboard/InfoPlist.xcstrings",
        root / "Voxboard Keyboard/InfoPlist.xcstrings",
        root / "Voxboard Widget/InfoPlist.xcstrings",
        root / "Voxboard Watch/InfoPlist.xcstrings",
        root / "Voxboard Watch Widget/InfoPlist.xcstrings",
        root / "Voxboard Mac/InfoPlist.xcstrings",
        root / "Voxboard Share Extension/InfoPlist.xcstrings",
    ]


def source_value(key: str, entry: dict) -> str:
    return (
        entry.get("localizations", {})
        .get("en", {})
        .get("stringUnit", {})
        .get("value", key)
    )


def translated_value(entry: dict, locale: str) -> str | None:
    unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit")
    if not unit or unit.get("state") not in {"translated", "needs_review"}:
        return None
    return unit.get("value")


def set_translation(entry: dict, locale: str, value: str) -> None:
    entry.setdefault("localizations", {})[locale] = {
        "stringUnit": {"state": "translated", "value": value}
    }


def glossary_value(source: str, locale: str) -> str | None:
    if locale == "en":
        return source
    if source == "Capture to Vox.md":
        return CAPTURE_TO_VOX[locale]
    try:
        index = GLOSSARY_SOURCES.index(source)
    except ValueError:
        return None
    return GLOSSARY[locale][index]


def reviewed_override(source: str, locale: str) -> str | None:
    if locale == "en":
        return None
    if source == "APPLE INTELLIGENCE":
        return "Apple Intelligence"
    if source == "VOX.MD":
        return "Vox.md"
    if source == "IOS":
        return "iOS"
    if source == "MACOS 26+":
        return "macOS 26+"
    if source in {"Slugify", "ZenQuotes ↗"}:
        return source
    return (
        SCREENSHOT_REVIEWED_OVERRIDES.get(source, {}).get(locale)
        or REVIEWED_OVERRIDES.get(source, {}).get(locale)
    )


def ensure_screenshot_override_entries(catalogs: list[dict]) -> int:
    """Add screenshot-only debug fixture strings that extraction cannot see."""
    strings = catalogs[0]["strings"]
    count = 0
    for source in SCREENSHOT_REVIEWED_OVERRIDES:
        if source in strings:
            continue
        strings[source] = {
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": source}}
            }
        }
        count += 1
    return count


def apply_reviewed_overrides(catalogs: list[dict], locales: list[str]) -> int:
    count = 0
    for catalog in catalogs:
        for key, entry in catalog["strings"].items():
            if not key or entry.get("shouldTranslate") is False:
                continue
            source = source_value(key, entry)
            for locale in locales:
                value = reviewed_override(source, locale)
                if value is None or translated_value(entry, locale) == value:
                    continue
                validate_preservation(source, value)
                set_translation(entry, locale, value)
                count += 1
    return count


def mask_text(value: str) -> MaskedText:
    replacements: list[str] = []

    def replace(match: re.Match[str]) -> str:
        index = len(replacements)
        if index > 999:
            raise ValueError("Too many protected tokens in one string")
        replacements.append(match.group(0))
        return f"ZXQ{index:03d}QXZ"

    return MaskedText(PROTECTED_PATTERN.sub(replace, value), tuple(replacements))


def restore_text(value: str, masked: MaskedText) -> str:
    found = [int(match.group(1)) for match in TOKEN_PATTERN.finditer(value)]
    expected = list(range(len(masked.replacements)))
    if found != expected:
        raise ValueError(f"protected token mismatch: expected {expected}, found {found}: {value!r}")

    def restore(match: re.Match[str]) -> str:
        return masked.replacements[int(match.group(1))]

    return TOKEN_PATTERN.sub(restore, value)


def technical_only(value: str) -> bool:
    masked = mask_text(value).value
    remainder = TOKEN_PATTERN.sub("", masked)
    return re.search(r"[^\W\d_]", remainder, re.UNICODE) is None


def chunks(values: list[str], size: int) -> Iterable[list[str]]:
    for index in range(0, len(values), size):
        yield values[index : index + size]


def choose_device(requested: str) -> str:
    import torch

    if requested == "auto":
        return "mps" if torch.backends.mps.is_available() else "cpu"
    return requested


def translate_batch(
    tokenizer: M2M100Tokenizer,
    model: M2M100ForConditionalGeneration,
    values: list[str],
    target_language: str,
    device: str,
    beams: int,
) -> list[str]:
    import torch

    tokenizer.src_lang = "en"
    encoded = tokenizer(
        values,
        return_tensors="pt",
        padding=True,
        truncation=True,
        max_length=512,
    ).to(device)
    with torch.inference_mode():
        input_length = encoded["input_ids"].shape[1]
        generation_options = {
            "forced_bos_token_id": tokenizer.get_lang_id(target_language),
            "num_beams": beams,
            "early_stopping": beams > 1,
            "max_new_tokens": min(128, max(24, int(input_length * 1.6) + 8)),
            "repetition_penalty": 1.05,
            "renormalize_logits": True,
        }
        if beams > 1:
            generation_options["no_repeat_ngram_size"] = 3
        generated = model.generate(**encoded, **generation_options)
    return tokenizer.batch_decode(generated, skip_special_tokens=True)


def translate_with_token_safe_fallback(
    tokenizer: M2M100Tokenizer,
    model: M2M100ForConditionalGeneration,
    task: TranslationTask,
    masked: MaskedText,
    locale: str,
    device: str,
    beams: int,
) -> str:
    # Translate the natural-language spans independently
    # and splice protected content back at its exact source position. This is
    # less flexible about word order, but cannot corrupt customer data tokens.
    pieces: list[tuple[str, bool]] = []
    cursor = 0
    for match in PROTECTED_PATTERN.finditer(task.source):
        if match.start() > cursor:
            pieces.append((task.source[cursor : match.start()], True))
        pieces.append((match.group(0), False))
        cursor = match.end()
    if cursor < len(task.source):
        pieces.append((task.source[cursor:], True))

    natural_indices = [
        index
        for index, (piece, should_translate) in enumerate(pieces)
        if should_translate and re.search(r"[^\W\d_]", piece, re.UNICODE)
    ]
    if natural_indices:
        natural_values: list[str] = []
        natural_whitespace: list[tuple[str, str]] = []
        for index in natural_indices:
            piece = pieces[index][0]
            leading = re.match(r"^\s*", piece).group(0)
            trailing = re.search(r"\s*$", piece).group(0)
            end = len(piece) - len(trailing) if trailing else len(piece)
            natural_values.append(piece[len(leading) : end])
            natural_whitespace.append((leading, trailing))
        outputs = translate_batch(
            tokenizer,
            model,
            natural_values,
            MODEL_LANGUAGE.get(locale, locale),
            device,
            1,
        )
        for index, output, whitespace in zip(natural_indices, outputs, natural_whitespace):
            pieces[index] = (f"{whitespace[0]}{output}{whitespace[1]}", True)
    value = "".join(piece for piece, _ in pieces)
    validate_preservation(task.source, value)
    print(f"{locale}: token-safe segmented fallback for {task.source!r}", flush=True)
    return value


def translate_protected_tasks(
    tokenizer: M2M100Tokenizer,
    model: M2M100ForConditionalGeneration,
    tasks: list[TranslationTask],
    locale: str,
    device: str,
    batch_size: int,
) -> list[str]:
    plans: list[list[str]] = []
    placements: list[tuple[int, int, str, str]] = []
    natural_values: list[str] = []

    def split_natural_piece(piece: str, maximum_characters: int = 120) -> list[str]:
        clauses = re.findall(r".*?(?:[.!?;:](?=\s|$)|,\s|$)", piece, re.DOTALL)
        result: list[str] = []
        for clause in clauses or [piece]:
            remaining = clause
            while len(remaining) > maximum_characters:
                split_at = remaining.rfind(" ", 0, maximum_characters + 1)
                if split_at <= 0:
                    split_at = maximum_characters
                else:
                    split_at += 1
                result.append(remaining[:split_at])
                remaining = remaining[split_at:]
            if remaining:
                result.append(remaining)
        return result

    for plan_index, task in enumerate(tasks):
        pieces: list[str] = []
        cursor = 0
        for match in PROTECTED_PATTERN.finditer(task.source):
            if match.start() > cursor:
                pieces.extend(split_natural_piece(task.source[cursor : match.start()]))
            pieces.append(match.group(0))
            cursor = match.end()
        if cursor < len(task.source):
            pieces.extend(split_natural_piece(task.source[cursor:]))
        plans.append(pieces)

        protected_values = preserved_tokens(task.source)
        for piece_index, piece in enumerate(pieces):
            if piece in protected_values or not re.search(r"[^\W\d_]", piece, re.UNICODE):
                continue
            leading = re.match(r"^\s*", piece).group(0)
            trailing = re.search(r"\s*$", piece).group(0)
            end = len(piece) - len(trailing) if trailing else len(piece)
            placements.append((plan_index, piece_index, leading, trailing))
            natural_values.append(piece[len(leading) : end])

    # Keep similarly sized fragments together so a single long help sentence
    # does not force every short label in its batch through the same padded
    # encoder/decoder window. Restore the original placement order afterward.
    indexed_values = sorted(enumerate(natural_values), key=lambda item: len(item[1]))
    translated_segments = [""] * len(natural_values)
    for batch in chunks(indexed_values, min(batch_size, 16)):
        outputs = translate_batch(
            tokenizer,
            model,
            [value for _, value in batch],
            MODEL_LANGUAGE.get(locale, locale),
            device,
            1,
        )
        for (original_index, _), output in zip(batch, outputs):
            translated_segments[original_index] = output
    for placement, output in zip(placements, translated_segments):
        plan_index, piece_index, leading, trailing = placement
        plans[plan_index][piece_index] = f"{leading}{output}{trailing}"

    values = ["".join(pieces) for pieces in plans]
    for task, value in zip(tasks, values):
        validate_preservation(task.source, value)
    return values


def preserved_tokens(value: str) -> Counter[str]:
    return Counter(match.group(0) for match in PROTECTED_PATTERN.finditer(value))


def validate_preservation(source: str, translated: str) -> None:
    expected = preserved_tokens(source)
    actual = Counter({token: translated.count(token) for token in expected})
    missing = expected - actual
    if missing:
        raise ValueError(f"protected content missing from translation: {dict(missing)}")


def write_catalogs(paths: list[Path], catalogs: list[dict]) -> None:
    for path, catalog in zip(paths, catalogs):
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.replace(path)


def tasks_for_locale(catalogs: list[dict], locale: str, overwrite: bool) -> list[TranslationTask]:
    tasks: list[TranslationTask] = []
    for catalog_index, catalog in enumerate(catalogs):
        for key, entry in catalog["strings"].items():
            if not key or entry.get("shouldTranslate") is False:
                continue
            if not overwrite and translated_value(entry, locale) is not None:
                continue
            tasks.append(TranslationTask(catalog_index, key, source_value(key, entry)))
    return tasks


def complete_english(catalogs: list[dict]) -> int:
    count = 0
    for catalog in catalogs:
        for key, entry in catalog["strings"].items():
            if not key or entry.get("shouldTranslate") is False:
                continue
            if translated_value(entry, "en") is None:
                set_translation(entry, "en", source_value(key, entry))
                count += 1
    return count


def complete_traditional_chinese(catalogs: list[dict], overwrite: bool) -> int:
    from opencc import OpenCC

    converter = OpenCC("s2tw")
    count = 0
    for catalog in catalogs:
        for key, entry in catalog["strings"].items():
            if not key or entry.get("shouldTranslate") is False:
                continue
            if not overwrite and translated_value(entry, "zh-Hant") is not None:
                continue
            source = source_value(key, entry)
            glossary = glossary_value(source, "zh-Hant")
            simplified = translated_value(entry, "zh-Hans")
            if glossary is not None:
                value = glossary
            elif simplified is not None:
                value = converter.convert(simplified)
            elif technical_only(source):
                value = source
            else:
                raise ValueError(f"zh-Hans must be completed before zh-Hant: {key!r}")
            validate_preservation(source, value)
            set_translation(entry, "zh-Hant", value)
            count += 1
    return count


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[2]
    paths = args.catalogs or default_catalogs(root)
    paths = [path if path.is_absolute() else root / path for path in paths]
    catalogs = [json.loads(path.read_text(encoding="utf-8")) for path in paths]

    invalid = sorted(set(args.locales) - set(RUNTIME_LOCALES))
    if invalid:
        raise ValueError(f"Unsupported runtime locale(s): {', '.join(invalid)}")

    added_override_entries = ensure_screenshot_override_entries(catalogs)
    if added_override_entries:
        write_catalogs(paths, catalogs)
    print(f"Screenshot override entries: added {added_override_entries}", flush=True)

    if "en" in args.locales:
        print(f"en: completed {complete_english(catalogs)} source entries", flush=True)
        write_catalogs(paths, catalogs)

    override_count = apply_reviewed_overrides(catalogs, args.locales)
    if override_count:
        write_catalogs(paths, catalogs)
    print(f"Reviewed overrides: applied {override_count} entries", flush=True)
    if args.overrides_only:
        return 0

    model_locales = [locale for locale in args.locales if locale not in {"en", "zh-Hant"}]
    if model_locales:
        from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer

        device = choose_device(args.device)
        print(f"Loading {args.model} on {device}", flush=True)
        tokenizer = M2M100Tokenizer.from_pretrained(args.model, local_files_only=True)
        model = M2M100ForConditionalGeneration.from_pretrained(
            args.model,
            local_files_only=True,
        ).to(device).eval()

        for locale in model_locales:
            tasks = tasks_for_locale(catalogs, locale, args.overwrite)
            immediate: list[tuple[TranslationTask, str]] = []
            pending: list[tuple[TranslationTask, MaskedText]] = []
            for task in tasks:
                glossary = reviewed_override(task.source, locale) or glossary_value(task.source, locale)
                if glossary is not None:
                    immediate.append((task, glossary))
                elif technical_only(task.source):
                    immediate.append((task, task.source))
                else:
                    pending.append((task, mask_text(task.source)))

            for task, value in immediate:
                validate_preservation(task.source, value)
                set_translation(catalogs[task.catalog_index]["strings"][task.key], locale, value)

            plain_pending = [item for item in pending if not item[1].replacements]
            protected_pending = [item for item in pending if item[1].replacements]
            plain_pending.sort(key=lambda item: len(item[1].value))
            protected_pending.sort(key=lambda item: len(item[0].source))
            plain_batches = list(chunks(plain_pending, args.batch_size))
            protected_batches = list(chunks(protected_pending, args.batch_size))
            total_batches = len(plain_batches) + len(protected_batches)
            print(
                f"{locale}: {len(tasks)} missing; {len(immediate)} protected/glossary; "
                f"{len(pending)} model translations in {total_batches} batches",
                flush=True,
            )
            batch_index = 0
            for batch in plain_batches:
                batch_index += 1
                masked_values = [item[1].value for item in batch]
                outputs = translate_batch(
                    tokenizer,
                    model,
                    masked_values,
                    MODEL_LANGUAGE.get(locale, locale),
                    device,
                    args.beams,
                )
                for (task, masked), output in zip(batch, outputs):
                    value = restore_text(output, masked)
                    validate_preservation(task.source, value)
                    set_translation(catalogs[task.catalog_index]["strings"][task.key], locale, value)
                if batch_index == 1 or batch_index % 10 == 0 or batch_index == total_batches:
                    print(f"{locale}: batch {batch_index}/{total_batches}", flush=True)
                if batch_index % 10 == 0:
                    write_catalogs(paths, catalogs)

            for batch in protected_batches:
                batch_index += 1
                batch_tasks = [item[0] for item in batch]
                values = translate_protected_tasks(
                    tokenizer,
                    model,
                    batch_tasks,
                    locale,
                    device,
                    args.batch_size,
                )
                for task, value in zip(batch_tasks, values):
                    set_translation(catalogs[task.catalog_index]["strings"][task.key], locale, value)
                if batch_index == 1 or batch_index % 10 == 0 or batch_index == total_batches:
                    print(f"{locale}: batch {batch_index}/{total_batches}", flush=True)
                if batch_index % 10 == 0:
                    write_catalogs(paths, catalogs)

            write_catalogs(paths, catalogs)
            print(f"{locale}: checkpointed", flush=True)
            if device == "mps":
                torch.mps.empty_cache()

    if "zh-Hant" in args.locales:
        completed = complete_traditional_chinese(catalogs, args.overwrite)
        write_catalogs(paths, catalogs)
        print(f"zh-Hant: completed {completed} entries from zh-Hans", flush=True)

    print("Runtime catalogs complete", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr, flush=True)
        raise
