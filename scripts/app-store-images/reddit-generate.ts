#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";
import OpenAI from "openai";
import sharp from "sharp";

const __filename = fileURLToPath(import.meta.url);
const toolDir = path.dirname(__filename);
const repoRoot = path.resolve(toolDir, "../..");
const outputDir = path.join(repoRoot, "app-store-output/reddit");
const backgroundsDir = path.join(outputDir, "backgrounds");
const finalDir = path.join(outputDir, "final");

const TARGET_WIDTH = 1600;
const TARGET_HEIGHT = 2000;
const BACKGROUND_SIZE = "1024x1536";
const MODEL = "gpt-image-2";
const QUALITY = "medium";
const MAX_IMAGES = 3;
const RETRIES_PER_IMAGE = 1;
const KEYCHAIN_SERVICE = "appstore-ai-images.openai-api-key";
const KEYCHAIN_ACCOUNT = "default";

const args = new Set(process.argv.slice(2));
const generate = args.has("--generate");
const force = args.has("--force");
if (args.has("--dry-run") && generate) {
  throw new Error("Use either --dry-run or --generate, not both.");
}

const cards = [
  {
    slug: "01-capture-anything",
    screenshot: "app-store-input/screenshots/01-quick-capture.png",
    headline: ["Capture anything", "to Obsidian"],
    subheadline: ["Text, files, scans, sketches, and voice"],
    accent: "#1677FF",
    prompt: [
      "Abstract portrait marketing background for Vox.md, a local-first Markdown capture app.",
      "Warm off-white paper-like background with extremely subtle paper grain, sparse charcoal Markdown punctuation, faint file-link lines, and restrained cobalt-blue accents.",
      "Editorial, technical, quiet, precise, premium but not glossy.",
      "Keep the top area calm and the center-lower area visually simple for a phone screenshot.",
      "No text, no letters, no numbers, no logos, no Obsidian logo, no devices, no phone frame, no app UI, no screens, no people, no stock photography.",
    ].join(" "),
  },
  {
    slug: "02-send-it-where-it-belongs",
    screenshot: "app-store-input/screenshots/02-preset-configuration.png",
    headline: ["Send it where", "it belongs"],
    subheadline: ["Daily notes, headings, inboxes, and templates"],
    accent: "#8FA8FF",
    prompt: [
      "Abstract portrait marketing background for Vox.md, a local-first productivity app that routes captures into Markdown files.",
      "Graphite and charcoal palette with soft gray depth, restrained cobalt highlights, and thin branching geometry inspired by a local file tree and linked notes.",
      "Clean editorial composition, calm and technical, with no cloud-service imagery.",
      "Keep the top area calm and the center-lower area visually simple for a phone screenshot.",
      "No text, no letters, no numbers, no logos, no folder icons, no arrows, no devices, no phone frame, no app UI, no screens, no people.",
    ].join(" "),
  },
  {
    slug: "03-transcription-stays-local",
    screenshot: "app-store-input/screenshots/03-local-models.png",
    headline: ["Transcription stays", "on your device"],
    subheadline: ["Apple Speech, Whisper, or Parakeet"],
    accent: "#54A2FF",
    prompt: [
      "Abstract portrait marketing background for Vox.md, an on-device speech transcription and Markdown capture app.",
      "Deep black and graphite background with a restrained cobalt waveform that resolves into tiny local processing nodes near the lower center.",
      "Private, technical, calm, and modern. Use soft depth without looking futuristic or cyberpunk.",
      "Keep the top area calm and the center-lower area visually simple for a phone screenshot.",
      "No text, no letters, no numbers, no logos, no cloud imagery, no shield icon, no devices, no phone frame, no app UI, no screens, no people.",
    ].join(" "),
  },
] as const;

if (cards.length > MAX_IMAGES) {
  throw new Error(`Refusing to plan ${cards.length} images because the campaign cap is ${MAX_IMAGES}.`);
}

dotenv.config({ path: path.join(repoRoot, ".env"), override: false });
dotenv.config({ path: path.join(toolDir, ".env"), override: false });

function getApiKey(required: boolean): string | undefined {
  if (process.env.OPENAI_API_KEY?.trim()) return process.env.OPENAI_API_KEY.trim();
  try {
    const key = execFileSync(
      "security",
      ["find-generic-password", "-a", KEYCHAIN_ACCOUNT, "-s", KEYCHAIN_SERVICE, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (key) return key;
  } catch {
    // The caller reports a missing credential without exposing secret values.
  }
  if (required) {
    throw new Error(
      "OpenAI credential missing. Export OPENAI_API_KEY or run `npm --prefix scripts/app-store-images run store-key`.",
    );
  }
  return undefined;
}

function credentialSource(): "env" | "keychain" | "missing" {
  if (process.env.OPENAI_API_KEY?.trim()) return "env";
  return getApiKey(false) ? "keychain" : "missing";
}

function repoPath(relative: string): string {
  return path.join(repoRoot, relative);
}

function ensureInputs(): void {
  for (const card of cards) {
    const screenshotPath = repoPath(card.screenshot);
    if (!fs.existsSync(screenshotPath)) {
      throw new Error(`Missing screenshot: ${card.screenshot}`);
    }
  }
}

function ensureOutputDirs(): void {
  fs.mkdirSync(backgroundsDir, { recursive: true });
  fs.mkdirSync(finalDir, { recursive: true });
}

function outputPaths(card: (typeof cards)[number]) {
  return {
    background: path.join(backgroundsDir, `${card.slug}-background.png`),
    final: path.join(finalDir, `${card.slug}.png`),
  };
}

function preflightOutputs(): void {
  if (force) return;
  const existing = cards
    .flatMap((card) => Object.values(outputPaths(card)))
    .filter((file) => fs.existsSync(file));
  if (existing.length > 0) {
    throw new Error(
      `Refusing to overwrite existing images without --force:\n${existing
        .map((file) => `- ${path.relative(repoRoot, file)}`)
        .join("\n")}`,
    );
  }
}

async function requestBackground(client: OpenAI, prompt: string): Promise<Buffer> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= RETRIES_PER_IMAGE; attempt += 1) {
    try {
      const result = await client.images.generate({
        model: MODEL,
        prompt,
        size: BACKGROUND_SIZE,
        quality: QUALITY,
        n: 1,
      });
      const image = result.data?.[0];
      if (image?.b64_json) return Buffer.from(image.b64_json, "base64");
      if (image?.url) {
        const response = await fetch(image.url);
        if (!response.ok) throw new Error(`Image download failed with HTTP ${response.status}.`);
        return Buffer.from(await response.arrayBuffer());
      }
      throw new Error("OpenAI returned no image data.");
    } catch (error) {
      lastError = error;
      if (attempt < RETRIES_PER_IMAGE) {
        console.warn(`Background generation failed; retrying once. ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
  throw new Error(`Background generation failed: ${lastError instanceof Error ? lastError.message : String(lastError)}`);
}

async function createPhoneLayer(screenshotPath: string): Promise<{ buffer: Buffer; left: number; top: number }> {
  const metadata = await sharp(screenshotPath).metadata();
  if (!metadata.width || !metadata.height) throw new Error(`Could not read screenshot dimensions: ${screenshotPath}`);

  const maxInnerHeight = 1325;
  const screenshotAspect = metadata.width / metadata.height;
  const innerHeight = maxInnerHeight;
  const innerWidth = Math.round(innerHeight * screenshotAspect);
  const framePadding = 22;
  const shadowPadding = 52;
  const frameWidth = innerWidth + framePadding * 2;
  const frameHeight = innerHeight + framePadding * 2;
  const layerWidth = frameWidth + shadowPadding * 2;
  const layerHeight = frameHeight + shadowPadding * 2;
  const outerRadius = 64;
  const innerRadius = 48;

  const screenshot = await sharp(screenshotPath)
    .resize(innerWidth, innerHeight, { fit: "contain" })
    .png()
    .toBuffer();
  const mask = Buffer.from(`
    <svg width="${innerWidth}" height="${innerHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${innerWidth}" height="${innerHeight}" rx="${innerRadius}" fill="#fff"/>
    </svg>
  `);
  const roundedScreenshot = await sharp(screenshot)
    .composite([{ input: mask, blend: "dest-in" }])
    .png()
    .toBuffer();

  const frameSvg = Buffer.from(`
    <svg width="${layerWidth}" height="${layerHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect x="${shadowPadding + 12}" y="${shadowPadding + 24}" width="${frameWidth}" height="${frameHeight}" rx="${outerRadius}" fill="#000" opacity="0.30"/>
      <rect x="${shadowPadding}" y="${shadowPadding}" width="${frameWidth}" height="${frameHeight}" rx="${outerRadius}" fill="#11110F"/>
    </svg>
  `);
  const buffer = await sharp(frameSvg)
    .composite([
      {
        input: roundedScreenshot,
        left: shadowPadding + framePadding,
        top: shadowPadding + framePadding,
      },
    ])
    .png()
    .toBuffer();

  return {
    buffer,
    left: Math.round((TARGET_WIDTH - layerWidth) / 2),
    top: 510,
  };
}

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function textOverlay(card: (typeof cards)[number]): Buffer {
  const headline = card.headline
    .map(
      (line, index) =>
        `<text x="132" y="${238 + index * 92}" font-family="Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="84" font-weight="700" letter-spacing="-3" fill="#F7F7F3">${escapeXml(line)}</text>`,
    )
    .join("\n");
  const subheadline = card.subheadline
    .map(
      (line, index) =>
        `<text x="136" y="${430 + index * 48}" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="34" font-weight="500" fill="#F7F7F3" opacity="0.86">${escapeXml(line)}</text>`,
    )
    .join("\n");

  return Buffer.from(`
    <svg width="${TARGET_WIDTH}" height="${TARGET_HEIGHT}" xmlns="http://www.w3.org/2000/svg">
      <rect x="82" y="72" width="1436" height="414" rx="52" fill="#11110F" opacity="0.84"/>
      <rect x="132" y="120" width="86" height="9" rx="4.5" fill="${card.accent}"/>
      <text x="132" y="172" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="25" font-weight="700" letter-spacing="5" fill="${card.accent}">VOX.MD</text>
      ${headline}
      ${subheadline}
    </svg>
  `);
}

async function compositeCard(card: (typeof cards)[number], backgroundPath: string, finalPath: string): Promise<void> {
  const phone = await createPhoneLayer(repoPath(card.screenshot));
  await sharp(backgroundPath)
    .resize(TARGET_WIDTH, TARGET_HEIGHT, { fit: "cover", position: "center" })
    .composite([
      { input: textOverlay(card), left: 0, top: 0 },
      { input: phone.buffer, left: phone.left, top: phone.top },
    ])
    .png()
    .toFile(finalPath);
}

function writeManifest(paid: boolean, filesCreated: string[]): void {
  const manifest = {
    timestamp: new Date().toISOString(),
    campaign: "Vox.md Reddit v2 announcement",
    appName: "Vox.md",
    provider: "openai-direct",
    model: MODEL,
    quality: QUALITY,
    credentialSource: credentialSource(),
    paid,
    dryRun: !paid,
    plannedImageGenerations: cards.length,
    maxImages: MAX_IMAGES,
    maxVariantsPerScreen: 1,
    retriesPerImage: RETRIES_PER_IMAGE,
    aiBackgroundSize: BACKGROUND_SIZE,
    outputDimensions: { width: TARGET_WIDTH, height: TARGET_HEIGHT, label: "Reddit portrait 4:5" },
    screenshotsSentToOpenAI: false,
    cards: cards.map((card) => ({
      slug: card.slug,
      screenshot: card.screenshot,
      headline: card.headline.join(" "),
      subheadline: card.subheadline.join(" "),
      prompt: card.prompt,
    })),
    filesCreated,
    assumptions: [
      "OpenAI generated abstract backgrounds only.",
      "Real Vox.md screenshots were composited locally without being sent to OpenAI.",
      "The campaign is a local draft and was not uploaded or published.",
    ],
  };
  fs.writeFileSync(path.join(outputDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}

async function main(): Promise<void> {
  ensureInputs();
  ensureOutputDirs();

  console.log("Vox.md Reddit image campaign");
  console.log("============================");
  console.log(`Mode: ${generate ? "generate (paid OpenAI calls enabled)" : "dry-run (no paid calls)"}`);
  console.log(`Planned images: ${cards.length}`);
  console.log(`Model: ${MODEL}`);
  console.log(`Quality: ${QUALITY}`);
  console.log(`AI background size: ${BACKGROUND_SIZE}`);
  console.log(`Final size: ${TARGET_WIDTH}x${TARGET_HEIGHT}`);
  console.log(`Credential source: ${credentialSource()}`);
  for (const [index, card] of cards.entries()) {
    console.log(`\n${index + 1}. ${card.headline.join(" ")}`);
    console.log(`   Screenshot: ${card.screenshot}`);
    console.log(`   Prompt: ${card.prompt}`);
  }

  if (!generate) {
    writeManifest(false, ["app-store-output/reddit/manifest.json"]);
    console.log("\nDry run complete. No AI calls were made.");
    return;
  }

  preflightOutputs();
  const apiKey = getApiKey(true);
  const client = new OpenAI({ apiKey });
  const filesCreated: string[] = [];

  for (const [index, card] of cards.entries()) {
    const paths = outputPaths(card);
    console.log(`\nGenerating ${index + 1}/${cards.length}: ${card.slug}`);
    const background = await requestBackground(client, card.prompt);
    fs.writeFileSync(paths.background, background);
    filesCreated.push(path.relative(repoRoot, paths.background));

    console.log(`Compositing ${path.relative(repoRoot, paths.final)}`);
    await compositeCard(card, paths.background, paths.final);
    filesCreated.push(path.relative(repoRoot, paths.final));
  }

  filesCreated.push("app-store-output/reddit/manifest.json");
  writeManifest(true, filesCreated);
  console.log("\nGeneration complete. Nothing was uploaded or published.");
}

main().catch((error) => {
  console.error(`\nError: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
