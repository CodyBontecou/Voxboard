#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const sharp = require("sharp");

const repoRoot = path.resolve(__dirname, "../..");
const screenshotRoot = path.join(repoRoot, "artifacts/localization/screenshots/raw");
const metadataRoot = path.join(repoRoot, "artifacts/localization/metadata-proposal/fastlane");
const outputRoot = path.join(repoRoot, "artifacts/localization/app-store-generated");
const appIconPath = path.join(repoRoot, "Voxboard/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png");

const localeMap = {
  "ar-SA": "ar",
  "de-DE": "de",
  "es-ES": "es",
  "es-MX": "es",
  "fr-FR": "fr",
  "fr-CA": "fr",
  hi: "hi",
  id: "id",
  it: "it",
  ja: "ja",
  ko: "ko",
  "nl-NL": "nl",
  pl: "pl",
  "pt-BR": "pt-BR",
  ru: "ru",
  th: "th",
  tr: "tr",
  uk: "uk",
  vi: "vi",
  "zh-Hans": "zh-Hans",
  "zh-Hant": "zh-Hant",
};

const supplemental = {
  "ar-SA": { history: "السجل", capture: "التقاط", workflow: "سير العمل", models: "النماذج", record: "تسجيل", private: "خصوصي", secure: "آمن", offline: "دون اتصال", speakAnyApp: "تحدث في أي تطبيق.", voiceToText: "من الصوت إلى نص" },
  "de-DE": { history: "Verlauf", capture: "Erfassen", workflow: "Arbeitsablauf", models: "Modelle", record: "Aufnehmen", private: "Privat", secure: "Sicher", offline: "Offline", speakAnyApp: "In jeder App diktieren.", voiceToText: "Sprache zu Text" },
  "es-ES": { history: "Historial", capture: "Captura", workflow: "Flujo de trabajo", models: "Modelos", record: "Grabar", private: "Privado", secure: "Seguro", offline: "Sin conexión", speakAnyApp: "Habla en cualquier app.", voiceToText: "Voz a texto" },
  "es-MX": { history: "Historial", capture: "Captura", workflow: "Flujo de trabajo", models: "Modelos", record: "Grabar", private: "Privado", secure: "Seguro", offline: "Sin conexión", speakAnyApp: "Habla en cualquier app.", voiceToText: "Voz a texto" },
  "fr-FR": { history: "Historique", capture: "Capture", workflow: "Flux de travail", models: "Modèles", record: "Enregistrer", private: "Privé", secure: "Sécurisé", offline: "Hors ligne", speakAnyApp: "Dictez dans n’importe quelle app.", voiceToText: "De la voix au texte" },
  "fr-CA": { history: "Historique", capture: "Capture", workflow: "Flux de travail", models: "Modèles", record: "Enregistrer", private: "Privé", secure: "Sécurisé", offline: "Hors ligne", speakAnyApp: "Dictez dans n’importe quelle app.", voiceToText: "De la voix au texte" },
  hi: { history: "इतिहास", capture: "कैप्चर", workflow: "वर्कफ़्लो", models: "मॉडल", record: "रिकॉर्डिंग", private: "निजी", secure: "सुरक्षित", offline: "ऑफ़लाइन", speakAnyApp: "किसी भी ऐप में बोलें।", voiceToText: "आवाज़ से टेक्स्ट" },
  id: { history: "Riwayat", capture: "Tangkapan", workflow: "Alur kerja", models: "Model", record: "Rekam", private: "Privat", secure: "Aman", offline: "Offline", speakAnyApp: "Bicara di aplikasi apa pun.", voiceToText: "Suara ke Teks" },
  it: { history: "Cronologia", capture: "Acquisizione", workflow: "Flusso di lavoro", models: "Modelli", record: "Registra", private: "Privato", secure: "Sicuro", offline: "Offline", speakAnyApp: "Parla in qualsiasi app.", voiceToText: "Da voce a testo" },
  ja: { history: "履歴", capture: "キャプチャ", workflow: "ワークフロー", models: "モデル", record: "録音", private: "プライベート", secure: "安全", offline: "オフライン", speakAnyApp: "どのアプリでも音声入力。", voiceToText: "音声をテキストに" },
  ko: { history: "기록", capture: "캡처", workflow: "워크플로", models: "모델", record: "녹음", private: "비공개", secure: "안전", offline: "오프라인", speakAnyApp: "어떤 앱에서든 음성 입력.", voiceToText: "음성을 텍스트로" },
  "nl-NL": { history: "Geschiedenis", capture: "Vastleggen", workflow: "Workflow", models: "Modellen", record: "Opnemen", private: "Privé", secure: "Veilig", offline: "Offline", speakAnyApp: "Spreek in elke app.", voiceToText: "Spraak naar tekst" },
  pl: { history: "Historia", capture: "Przechwytywanie", workflow: "Przepływ pracy", models: "Modele", record: "Nagrywanie", private: "Prywatne", secure: "Bezpieczne", offline: "Offline", speakAnyApp: "Mów w dowolnej aplikacji.", voiceToText: "Mowa na tekst" },
  "pt-BR": { history: "Histórico", capture: "Captura", workflow: "Fluxo de trabalho", models: "Modelos", record: "Gravar", private: "Privado", secure: "Seguro", offline: "Offline", speakAnyApp: "Fale em qualquer app.", voiceToText: "Voz em texto" },
  ru: { history: "История", capture: "Захват", workflow: "Рабочий процесс", models: "Модели", record: "Запись", private: "Конфиденциально", secure: "Безопасно", offline: "Офлайн", speakAnyApp: "Диктуйте в любом приложении.", voiceToText: "Речь в текст" },
  th: { history: "ประวัติ", capture: "การบันทึก", workflow: "เวิร์กโฟลว์", models: "โมเดล", record: "บันทึก", private: "เป็นส่วนตัว", secure: "ปลอดภัย", offline: "ออฟไลน์", speakAnyApp: "พูดในทุกแอป", voiceToText: "เสียงเป็นข้อความ" },
  tr: { history: "Geçmiş", capture: "Yakalama", workflow: "İş akışı", models: "Modeller", record: "Kayıt", private: "Özel", secure: "Güvenli", offline: "Çevrimdışı", speakAnyApp: "Her uygulamada konuşun.", voiceToText: "Sesten metne" },
  uk: { history: "Історія", capture: "Захоплення", workflow: "Робочий процес", models: "Моделі", record: "Запис", private: "Приватно", secure: "Безпечно", offline: "Офлайн", speakAnyApp: "Диктуйте в будь-якій програмі.", voiceToText: "Мовлення в текст" },
  vi: { history: "Lịch sử", capture: "Ghi nhanh", workflow: "Quy trình", models: "Mô hình", record: "Ghi âm", private: "Riêng tư", secure: "An toàn", offline: "Ngoại tuyến", speakAnyApp: "Nói trong mọi ứng dụng.", voiceToText: "Giọng nói thành văn bản" },
  "zh-Hans": { history: "历史记录", capture: "采集", workflow: "工作流程", models: "模型", record: "录音", private: "私密", secure: "安全", offline: "离线", speakAnyApp: "在任意 App 中语音输入。", voiceToText: "语音转文字" },
  "zh-Hant": { history: "歷史記錄", capture: "擷取", workflow: "工作流程", models: "模型", record: "錄音", private: "私密", secure: "安全", offline: "離線", speakAnyApp: "在任何 App 中語音輸入。", voiceToText: "語音轉文字" },
};

const iphonePlans = [
  { file: "01-capture-anything.png", story: "01-quick-capture", headline: "subtitle", subheadline: "Capture an idea, task, link, file, scan, or recording." },
  { file: "02-capture-workflows.png", story: "05-capture-presets", headline: "Capture Presets", subheadline: "A Capture Preset is a complete reusable workflow: what happens to a capture and exactly where it is delivered." },
  { file: "03-send-every-capture.png", story: "05-capture-presets", headline: "Destination", subheadline: "Processing, formatting, metadata, and destinations" },
  { file: "04-speak-into-any-app.png", story: "07-keyboard", headline: "speakAnyApp", subheadline: "Keyboard" },
  { file: "05-private-by-design.png", story: "06-privacy-local", headline: "private", subheadline: "Everything stays on this device." },
  { file: "06-record-without-breaking-flow.png", story: "02-live-recording", headline: "Record", subheadline: "Composer remains available while you record" },
  { file: "07-customize-capture-bar.png", story: "03-settings", headline: "Capture Bar", subheadline: "Choose, reorder, and hide quick actions" },
];

const ipadPlans = [
  { file: "01-voice-to-text.png", story: "01-quick-capture", headline: "voiceToText", subheadline: "Everything stays on this device.", layout: "top" },
  { file: "02-history.png", story: "02-history", headline: "history", subheadline: "Recordings, recording time, and Capture activity", layout: "bottom" },
  { file: "03-models.png", story: "04-models", headline: "On-Device Models", subheadline: "Optional local models you can download and select explicitly.", layout: "top" },
  { file: "04-settings.png", story: "03-settings", headline: "Settings", subheadline: "Transcription engines, model downloads, and language", layout: "bottom" },
  { file: "05-live-recording.png", story: "05-live-recording", headline: "Record", subheadline: "Live transcript · sending immediately", layout: "top" },
];

const watchPlans = [
  { file: "01-ready.png", story: "01-ready" },
  { file: "02-recording.png", story: "02-recording" },
  { file: "03-synced.png", story: "03-synced" },
];

const macPlans = [
  { file: "01-history.png", story: "02-history", number: "05", label: "history", headline: "history", subheadline: "Recordings, recording time, and Capture activity" },
  { file: "02-workflow.png", story: "05-presets", number: "04", label: "workflow", headline: "Capture Presets", subheadline: "A Capture Preset is a complete reusable workflow: what happens to a capture and exactly where it is delivered." },
  { file: "03-models.png", story: "04-models", number: "03", label: "models", headline: "On-Device Models", subheadline: "Optional local models you can download and select explicitly." },
  { file: "04-record.png", story: "01-capture", number: "02", label: "record", headline: "Record", subheadline: "Live transcript · sending immediately" },
  { file: "05-capture.png", story: "01-capture", number: "01", label: "capture", headline: "subtitle", subheadline: "Everything stays on this device." },
];

// A few automated captures were taken while the localized app content was in a
// disabled/faded transition state. Prefer another capture of the same localized
// settings screen when one is available. The remaining affected captures are
// recovered with a narrowly targeted highlight-contrast expansion below.
const screenshotSourceOverrides = {
  "ar-SA": { iphone: { "07-keyboard": "03-settings" } },
  pl: { iphone: { "03-settings": "07-keyboard" } },
  tr: { iphone: { "07-keyboard": "03-settings" } },
  "zh-Hans": { iphone: { "03-settings": "07-keyboard" } },
};

const screenshotTreatments = {
  "fr-FR/iphone/05-capture-presets": { highlightContrast: 10 },
  "fr-CA/ipad/01-quick-capture": { highlightContrast: 5 },
  "zh-Hans/iphone/07-keyboard": { highlightContrast: 4 },
};

function loadReviewedOverrides() {
  const script = [
    "import json",
    "from scripts.localization.screenshot_reviewed_overrides import SCREENSHOT_REVIEWED_OVERRIDES",
    "print(json.dumps(SCREENSHOT_REVIEWED_OVERRIDES, ensure_ascii=False))",
  ].join("\n");
  const result = spawnSync("/usr/bin/python3", ["-c", script], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`Could not load reviewed screenshot copy: ${result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout);
}

const reviewed = loadReviewedOverrides();

function textFor(locale, token) {
  if (token === "subtitle") {
    return fs.readFileSync(path.join(metadataRoot, locale, "subtitle.txt"), "utf8").trim();
  }
  if (supplemental[locale] && Object.hasOwn(supplemental[locale], token)) {
    return supplemental[locale][token];
  }
  const runtimeLocale = localeMap[locale];
  const value = reviewed[token]?.[runtimeLocale];
  if (!value) throw new Error(`Missing reviewed copy for ${locale}: ${token}`);
  return value;
}

function ensureInput(file) {
  if (!fs.existsSync(file)) throw new Error(`Missing input image: ${path.relative(repoRoot, file)}`);
}

function resolveScreenshotSource(locale, platform, requestedStory) {
  const story = screenshotSourceOverrides[locale]?.[platform]?.[requestedStory] ?? requestedStory;
  const inputPath = path.join(screenshotRoot, locale, platform, `${story}.png`);
  const treatment = screenshotTreatments[`${locale}/${platform}/${story}`] ?? {};
  ensureInput(inputPath);
  return { inputPath, story, treatment };
}

function escapeXml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function isRTL(locale) {
  return locale.startsWith("ar");
}

function hasComplexScript(text) {
  return /[\u0600-\u06ff\u0750-\u077f\u0900-\u0d7f\u0e00-\u0e7f\u1100-\u11ff\u2e80-\u9fff\uac00-\ud7af]/u.test(text);
}

function charWidth(char) {
  if (/\s/u.test(char)) return 0.32;
  if (/[\u2e80-\u9fff\uac00-\ud7af]/u.test(char)) return 1.0;
  if (/[\u0600-\u06ff\u0750-\u077f]/u.test(char)) return 0.62;
  if (/[\u0900-\u0d7f\u0e00-\u0e7f]/u.test(char)) return 0.72;
  if (/[A-Z0-9]/u.test(char)) return 0.64;
  if (/[.,:;!|·—–-]/u.test(char)) return 0.34;
  return 0.56;
}

function estimateWidth(text, fontSize, letterSpacing = 0) {
  return [...text].reduce((sum, char) => sum + charWidth(char) * fontSize + letterSpacing, 0);
}

function wrapText(text, maxWidth, fontSize, letterSpacing = 0) {
  const normalized = text.replace(/\s+/gu, " ").trim();
  if (!normalized) return [];
  // Thai and CJK commonly contain long runs without whitespace. Wrap those
  // scripts by grapheme-like code points even when the sentence has spaces.
  const characterWrapped = /[\u0e00-\u0e7f\u2e80-\u9fff\uac00-\ud7af]/u.test(normalized);
  const tokens = characterWrapped
    ? Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(normalized), (part) => part.segment)
    : normalized.split(" ");
  const joiner = characterWrapped ? "" : " ";
  const lines = [];
  let line = "";
  for (const token of tokens) {
    const candidate = line ? `${line}${joiner}${token}` : token;
    if (line && estimateWidth(candidate, fontSize, letterSpacing) > maxWidth) {
      lines.push(line);
      line = token;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  return lines;
}

function fitText(text, maxWidth, maxLines, initialSize, minSize, letterSpacing = 0) {
  for (let size = initialSize; size >= minSize; size -= 2) {
    const lines = wrapText(text, maxWidth, size, letterSpacing);
    if (lines.length <= maxLines) return { size, lines };
  }
  return { size: minSize, lines: wrapText(text, maxWidth, minSize, letterSpacing).slice(0, maxLines) };
}

function textBlock({ text, x, y, width, maxLines, size, minSize, lineHeight, fill, weight, locale, family, opacity = 1, letterSpacing = 0 }) {
  const fitted = fitText(text, width, maxLines, size, minSize, letterSpacing);
  const rtl = isRTL(locale);
  // librsvg resolves SVG start/end anchors after applying direction. For RTL,
  // `start` at the right edge produces the expected right-aligned text box.
  const anchor = "start";
  const textX = rtl ? x + width : x;
  const direction = rtl ? ' direction="rtl" unicode-bidi="plaintext"' : "";
  const spacing = hasComplexScript(text) ? 0 : letterSpacing;
  const actualLineHeight = Math.round(fitted.size * lineHeight);
  const tspans = fitted.lines
    .map((line, index) => `<tspan x="${textX}" dy="${index === 0 ? 0 : actualLineHeight}">${escapeXml(line)}</tspan>`)
    .join("");
  return {
    svg: `<text x="${textX}" y="${y}" text-anchor="${anchor}"${direction} font-family="${family}" font-size="${fitted.size}" font-weight="${weight}" letter-spacing="${spacing}" fill="${fill}" opacity="${opacity}">${tspans}</text>`,
    height: fitted.lines.length * actualLineHeight,
    size: fitted.size,
    lines: fitted.lines,
  };
}

const sans = "-apple-system, BlinkMacSystemFont, SF Pro Display, Noto Sans, Noto Sans Arabic, Arial Unicode MS, sans-serif";
const mono = "SF Mono, Menlo, Noto Sans Mono, Noto Sans, Noto Sans Arabic, Arial Unicode MS, monospace";

async function roundedImage(inputPath, width, height, radius, fit = "cover", treatment = {}) {
  let pipeline = sharp(inputPath);
  if (treatment.highlightContrast > 1) {
    const factor = treatment.highlightContrast;
    pipeline = pipeline.linear(factor, 255 * (1 - factor));
  }
  pipeline = pipeline.resize(width, height, {
    fit,
    position: "center",
    kernel: sharp.kernel.lanczos3,
  });
  if (treatment.sharpen) {
    pipeline = pipeline.sharpen({ sigma: treatment.sharpen });
  }
  const resized = await pipeline.png().toBuffer();
  const mask = Buffer.from(`<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg"><rect width="${width}" height="${height}" rx="${radius}" fill="#fff"/></svg>`);
  return sharp(resized).composite([{ input: mask, blend: "dest-in" }]).png().toBuffer();
}

async function deviceFrame(inputPath, options) {
  const { innerWidth, innerHeight, radius, border, frameColor, shadow, fit = "cover", sourceTreatment = {} } = options;
  const outerWidth = innerWidth + border * 2 + shadow * 2;
  const outerHeight = innerHeight + border * 2 + shadow * 2;
  const screenshot = await roundedImage(inputPath, innerWidth, innerHeight, radius, fit, {
    ...sourceTreatment,
    sharpen: sourceTreatment.sharpen ?? 0.55,
  });
  const frameRadius = radius + border;
  const svg = Buffer.from(`
    <svg width="${outerWidth}" height="${outerHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect x="${shadow + 8}" y="${shadow + 16}" width="${innerWidth + border * 2}" height="${innerHeight + border * 2}" rx="${frameRadius}" fill="#000" opacity="0.30"/>
      <rect x="${shadow}" y="${shadow}" width="${innerWidth + border * 2}" height="${innerHeight + border * 2}" rx="${frameRadius}" fill="${frameColor}"/>
    </svg>`);
  return sharp(svg).composite([{ input: screenshot, left: shadow + border, top: shadow + border }]).png().toBuffer();
}

function iphoneBackground(index) {
  const phase = 70 + index * 31;
  return Buffer.from(`
    <svg width="1320" height="2868" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <radialGradient id="paper" cx="50%" cy="35%" r="85%"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#f4f2ef"/></radialGradient>
        <pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="1.7" fill="#1688ff" opacity="0.28"/></pattern>
      </defs>
      <rect width="1320" height="2868" fill="url(#paper)"/>
      <rect x="1120" y="${phase}" width="170" height="210" fill="url(#dots)" opacity="0.75"/>
      <rect x="34" y="2310" width="145" height="190" fill="url(#dots)" opacity="0.42"/>
      <g fill="none" stroke="#1688ff" stroke-width="3" opacity="0.88">
        <path d="M -20 1680 C 35 1400, 62 2020, 110 1650 S 185 1450, 225 1780"/>
        <path d="M 1090 1570 C 1130 1280, 1170 1960, 1215 1580 S 1280 1420, 1350 1760"/>
      </g>
      <g stroke="#1688ff" opacity="0.36" stroke-width="2"><path d="M1120 520h24M1132 508v24"/><path d="M80 2550h24M92 2538v24"/></g>
    </svg>`);
}

async function generateIphone(locale, plan, index) {
  const { inputPath, story: sourceStory, treatment } = resolveScreenshotSource(locale, "iphone", plan.story);
  const outputDir = path.join(outputRoot, locale, "APP_IPHONE_67");
  fs.mkdirSync(outputDir, { recursive: true });

  const headline = textFor(locale, plan.headline);
  const subheadline = textFor(locale, plan.subheadline);
  const headlineBlock = textBlock({ text: headline, x: 100, y: 370, width: 1120, maxLines: 3, size: 94, minSize: 64, lineHeight: 1.02, fill: "#050505", weight: 800, locale, family: sans, letterSpacing: -2 });
  const subY = 370 + headlineBlock.height + 42;
  const subBlock = textBlock({ text: subheadline, x: 104, y: subY, width: 1110, maxLines: 3, size: 48, minSize: 34, lineHeight: 1.23, fill: "#65656b", weight: 500, locale, family: sans });
  const textLayer = Buffer.from(`<svg width="1320" height="2868" xmlns="http://www.w3.org/2000/svg">${headlineBlock.svg}${subBlock.svg}</svg>`);

  const phone = await deviceFrame(inputPath, {
    innerWidth: 842,
    innerHeight: 1824,
    radius: 92,
    border: 22,
    shadow: 34,
    frameColor: "#101012",
    sourceTreatment: treatment,
  });
  const icon = await roundedImage(appIconPath, 154, 154, 34, "cover");
  const iconX = isRTL(locale) ? 1066 : 96;
  const outputPath = path.join(outputDir, plan.file);
  await sharp(iphoneBackground(index))
    .composite([
      { input: icon, left: iconX, top: 88 },
      { input: textLayer, left: 0, top: 0 },
      { input: phone, left: 189, top: 915 },
    ])
    .png()
    .toFile(outputPath);
  return { outputPath, inputPath, sourceStory, treatment, headline, subheadline };
}

function ipadBackground() {
  return Buffer.from(`
    <svg width="2048" height="2732" xmlns="http://www.w3.org/2000/svg">
      <defs><radialGradient id="glow" cx="50%" cy="45%" r="70%"><stop offset="0" stop-color="#0c1010"/><stop offset="1" stop-color="#000"/></radialGradient></defs>
      <rect width="2048" height="2732" fill="url(#glow)"/>
      <path d="M0 0h2048v2732H0z" fill="none" stroke="#1b1b1d" stroke-width="2"/>
    </svg>`);
}

async function generateIpad(locale, plan) {
  const { inputPath, story: sourceStory, treatment } = resolveScreenshotSource(locale, "ipad", plan.story);
  const outputDir = path.join(outputRoot, locale, "APP_IPAD_PRO_3GEN_129");
  fs.mkdirSync(outputDir, { recursive: true });

  const headline = textFor(locale, plan.headline);
  const subheadline = textFor(locale, plan.subheadline);
  const copyY = plan.layout === "bottom" ? 1870 : 210;
  const family = hasComplexScript(headline + subheadline) ? sans : mono;
  const headlineBlock = textBlock({ text: headline, x: 86, y: copyY, width: 1760, maxLines: 3, size: 154, minSize: 92, lineHeight: 0.98, fill: "#ffffff", weight: 800, locale, family, letterSpacing: -2 });
  const accentWidth = Math.min(440, Math.max(150, headlineBlock.size * 2.2));
  const subY = copyY + headlineBlock.height + 56;
  const subBlock = textBlock({ text: subheadline, x: 88, y: subY, width: 1740, maxLines: 4, size: 58, minSize: 38, lineHeight: 1.28, fill: "#858589", weight: 500, locale, family });
  const textLayer = Buffer.from(`<svg width="2048" height="2732" xmlns="http://www.w3.org/2000/svg"><rect x="${isRTL(locale) ? 2048 - 88 - accentWidth : 88}" y="${copyY - 122}" width="${accentWidth}" height="14" rx="7" fill="#ff3b30"/>${headlineBlock.svg}${subBlock.svg}</svg>`);

  const frame = await deviceFrame(inputPath, {
    innerWidth: 1740,
    innerHeight: 1305,
    radius: 42,
    border: 14,
    shadow: 30,
    frameColor: "#4a4b50",
    fit: "cover",
    sourceTreatment: treatment,
  });
  const frameTop = plan.layout === "bottom" ? -105 : 1210;
  const outputPath = path.join(outputDir, plan.file);
  await sharp(ipadBackground())
    .composite([
      { input: frame, left: 110, top: frameTop },
      { input: textLayer, left: 0, top: 0 },
    ])
    .png()
    .toFile(outputPath);
  return { outputPath, inputPath, sourceStory, treatment, headline, subheadline };
}

async function generateWatch(locale, plan) {
  const { inputPath, story: sourceStory } = resolveScreenshotSource(locale, "watch", plan.story);
  const outputDir = path.join(outputRoot, locale, "APP_WATCH_SERIES_10");
  fs.mkdirSync(outputDir, { recursive: true });
  const outputPath = path.join(outputDir, plan.file);
  await sharp(inputPath).resize(416, 496, { fit: "cover", position: "center" }).png().toFile(outputPath);
  return { outputPath, inputPath, sourceStory };
}

function macBackground() {
  return Buffer.from(`
    <svg width="1440" height="900" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <radialGradient id="shade" cx="68%" cy="35%" r="85%"><stop offset="0" stop-color="#292a2b"/><stop offset="0.48" stop-color="#171819"/><stop offset="1" stop-color="#0c0d0e"/></radialGradient>
        <pattern id="grid" width="52" height="52" patternUnits="userSpaceOnUse"><path d="M52 0H0V52" fill="none" stroke="#fff" stroke-opacity="0.035" stroke-width="1"/></pattern>
      </defs>
      <rect width="1440" height="900" fill="url(#shade)"/>
      <rect width="1440" height="900" fill="url(#grid)"/>
      <g stroke="#8d8f91" stroke-width="1" opacity="0.55"><path d="M20 55V20h35M1385 20h35v35M20 845v35h35M1385 880h35v-35"/></g>
    </svg>`);
}

async function generateMac(locale, plan) {
  const { inputPath, story: sourceStory, treatment } = resolveScreenshotSource(locale, "mac", plan.story);
  const outputDir = path.join(outputRoot, locale, "APP_DESKTOP");
  fs.mkdirSync(outputDir, { recursive: true });

  const headline = textFor(locale, plan.headline);
  const subheadline = textFor(locale, plan.subheadline);
  const labelText = `${plan.number} — ${supplemental[locale][plan.label].toLocaleUpperCase(locale)}`;
  const label = textBlock({ text: labelText, x: 50, y: 300, width: 400, maxLines: 2, size: 18, minSize: 14, lineHeight: 1.18, fill: "#ff8a00", weight: 700, locale, family: mono, letterSpacing: 0.5 });
  const headlineBlock = textBlock({ text: headline, x: 48, y: 390, width: 410, maxLines: 4, size: 68, minSize: 44, lineHeight: 0.99, fill: "#ffffff", weight: 800, locale, family: sans, letterSpacing: -1.5 });
  const subY = 390 + headlineBlock.height + 34;
  const family = hasComplexScript(subheadline) ? sans : mono;
  const subBlock = textBlock({ text: subheadline, x: 50, y: subY, width: 395, maxLines: 5, size: 24, minSize: 17, lineHeight: 1.32, fill: "#d2d2d4", weight: 500, locale, family });
  const taglineText = `${supplemental[locale].private}  •  ${supplemental[locale].secure}  •  ${supplemental[locale].offline}`.toLocaleUpperCase(locale);
  const tagline = textBlock({ text: `[ ${taglineText} ]`, x: 50, y: 835, width: 400, maxLines: 2, size: 15, minSize: 12, lineHeight: 1.2, fill: "#d4d4d6", weight: 500, locale, family: mono, letterSpacing: 0.4 });
  const textLayer = Buffer.from(`<svg width="1440" height="900" xmlns="http://www.w3.org/2000/svg">${label.svg}${headlineBlock.svg}${subBlock.svg}${tagline.svg}</svg>`);

  const frame = await deviceFrame(inputPath, {
    innerWidth: 850,
    innerHeight: 478,
    radius: 20,
    border: 6,
    shadow: 20,
    frameColor: "#515256",
    fit: "cover",
    sourceTreatment: treatment,
  });
  const icon = await roundedImage(appIconPath, 70, 70, 16, "cover");
  const brand = Buffer.from(`<svg width="300" height="90" xmlns="http://www.w3.org/2000/svg"><text x="0" y="57" font-family="${mono}" font-size="22" font-weight="600" letter-spacing="2" fill="#f1f1f1">VOXBOARD</text></svg>`);
  const outputPath = path.join(outputDir, plan.file);
  await sharp(macBackground())
    .composite([
      { input: icon, left: 50, top: 60 },
      { input: brand, left: 142, top: 54 },
      { input: textLayer, left: 0, top: 0 },
      { input: frame, left: 494, top: 155 },
    ])
    .png()
    .toFile(outputPath);
  return { outputPath, inputPath, sourceStory, treatment, headline, subheadline, label: labelText, tagline: taglineText };
}

async function main() {
  ensureInput(appIconPath);
  const locales = Object.keys(localeMap);
  const manifest = {
    generatedAt: new Date().toISOString(),
    reference: "Live en-US App Store screenshots downloaded read-only to artifacts/localization/app-store-english-reference",
    strategy: "Deterministic raster compositing: English visual template, localized capture, reviewed localized overlay copy, and targeted source-quality recovery for faded captures",
    locales,
    sizes: {
      APP_IPHONE_67: [1320, 2868],
      APP_IPAD_PRO_3GEN_129: [2048, 2732],
      APP_WATCH_SERIES_10: [416, 496],
      APP_DESKTOP: [1440, 900],
    },
    images: [],
  };

  fs.mkdirSync(outputRoot, { recursive: true });
  for (const locale of locales) {
    process.stdout.write(`${locale}: `);
    for (let index = 0; index < iphonePlans.length; index += 1) {
      const item = await generateIphone(locale, iphonePlans[index], index);
      manifest.images.push({ locale, displayType: "APP_IPHONE_67", file: path.relative(outputRoot, item.outputPath), source: path.relative(repoRoot, item.inputPath), sourceStory: item.sourceStory, sourceTreatment: Object.keys(item.treatment).length ? item.treatment : undefined, headline: item.headline, subheadline: item.subheadline });
    }
    for (const plan of ipadPlans) {
      const item = await generateIpad(locale, plan);
      manifest.images.push({ locale, displayType: "APP_IPAD_PRO_3GEN_129", file: path.relative(outputRoot, item.outputPath), source: path.relative(repoRoot, item.inputPath), sourceStory: item.sourceStory, sourceTreatment: Object.keys(item.treatment).length ? item.treatment : undefined, headline: item.headline, subheadline: item.subheadline });
    }
    for (const plan of watchPlans) {
      const item = await generateWatch(locale, plan);
      manifest.images.push({ locale, displayType: "APP_WATCH_SERIES_10", file: path.relative(outputRoot, item.outputPath), source: path.relative(repoRoot, item.inputPath), sourceStory: item.sourceStory });
    }
    for (const plan of macPlans) {
      const item = await generateMac(locale, plan);
      manifest.images.push({ locale, displayType: "APP_DESKTOP", file: path.relative(outputRoot, item.outputPath), source: path.relative(repoRoot, item.inputPath), sourceStory: item.sourceStory, sourceTreatment: Object.keys(item.treatment).length ? item.treatment : undefined, headline: item.headline, subheadline: item.subheadline, label: item.label, tagline: item.tagline });
    }
    process.stdout.write("20 images\n");
  }

  const manifestPath = path.join(outputRoot, "manifest.json");
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`Generated ${manifest.images.length} localized App Store images.`);
  console.log(`Manifest: ${path.relative(repoRoot, manifestPath)}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exitCode = 1;
});
