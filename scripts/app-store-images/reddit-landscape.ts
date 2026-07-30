#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const __filename = fileURLToPath(import.meta.url);
const toolDir = path.dirname(__filename);
const repoRoot = path.resolve(toolDir, "../..");
const backgroundsDir = path.join(repoRoot, "app-store-output/reddit/backgrounds");
const outputDir = path.join(repoRoot, "app-store-output/reddit/final-landscape");
const width = 1600;
const height = 900;

const cards = [
  {
    slug: "01-capture-anything",
    screenshot: "app-store-input/screenshots/01-quick-capture.png",
    headline: ["Capture anything", "to Obsidian"],
    subheadline: ["Text, files, scans,", "sketches, and voice"],
    accent: "#1677FF",
  },
  {
    slug: "02-send-it-where-it-belongs",
    screenshot: "app-store-input/screenshots/02-preset-configuration.png",
    headline: ["Send it where", "it belongs"],
    subheadline: ["Daily notes, headings,", "inboxes, and templates"],
    accent: "#8FA8FF",
  },
  {
    slug: "03-transcription-stays-local",
    screenshot: "app-store-input/screenshots/03-local-models.png",
    headline: ["Transcription stays", "on your device"],
    subheadline: ["Apple Speech, Whisper,", "or Parakeet"],
    accent: "#54A2FF",
  },
] as const;

function escapeXml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function textPanel(card: (typeof cards)[number]): Buffer {
  const headline = card.headline
    .map(
      (line, index) =>
        `<text x="118" y="${265 + index * 92}" font-family="Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="82" font-weight="700" letter-spacing="-3" fill="#F7F7F3">${escapeXml(line)}</text>`,
    )
    .join("\n");
  const subheadline = card.subheadline
    .map(
      (line, index) =>
        `<text x="122" y="${500 + index * 46}" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="31" font-weight="500" fill="#F7F7F3" opacity="0.88">${escapeXml(line)}</text>`,
    )
    .join("\n");

  return Buffer.from(`
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <rect x="54" y="54" width="790" height="792" rx="54" fill="#11110F" opacity="0.88"/>
      <rect x="118" y="118" width="86" height="9" rx="4.5" fill="${card.accent}"/>
      <text x="118" y="173" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="25" font-weight="700" letter-spacing="5" fill="${card.accent}">VOX.MD</text>
      ${headline}
      ${subheadline}
      <text x="122" y="772" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="24" font-weight="600" letter-spacing="1" fill="#F7F7F3" opacity="0.60">vox.isolated.tech</text>
    </svg>
  `);
}

async function createPhoneLayer(screenshotPath: string): Promise<{ buffer: Buffer; left: number; top: number }> {
  const metadata = await sharp(screenshotPath).metadata();
  if (!metadata.width || !metadata.height) throw new Error(`Could not inspect ${screenshotPath}`);

  const innerHeight = 782;
  const innerWidth = Math.round(innerHeight * (metadata.width / metadata.height));
  const framePadding = 15;
  const shadowPadding = 30;
  const frameWidth = innerWidth + framePadding * 2;
  const frameHeight = innerHeight + framePadding * 2;
  const layerWidth = frameWidth + shadowPadding * 2;
  const layerHeight = frameHeight + shadowPadding * 2;
  const outerRadius = 46;
  const innerRadius = 34;

  const resized = await sharp(screenshotPath)
    .resize(innerWidth, innerHeight, { fit: "contain" })
    .png()
    .toBuffer();
  const mask = Buffer.from(`
    <svg width="${innerWidth}" height="${innerHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${innerWidth}" height="${innerHeight}" rx="${innerRadius}" fill="#fff"/>
    </svg>
  `);
  const screenshot = await sharp(resized)
    .composite([{ input: mask, blend: "dest-in" }])
    .png()
    .toBuffer();

  const frame = Buffer.from(`
    <svg width="${layerWidth}" height="${layerHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect x="${shadowPadding + 10}" y="${shadowPadding + 15}" width="${frameWidth}" height="${frameHeight}" rx="${outerRadius}" fill="#000" opacity="0.34"/>
      <rect x="${shadowPadding}" y="${shadowPadding}" width="${frameWidth}" height="${frameHeight}" rx="${outerRadius}" fill="#11110F"/>
    </svg>
  `);
  const buffer = await sharp(frame)
    .composite([
      {
        input: screenshot,
        left: shadowPadding + framePadding,
        top: shadowPadding + framePadding,
      },
    ])
    .png()
    .toBuffer();

  return {
    buffer,
    left: Math.round(1120 - layerWidth / 2),
    top: Math.round((height - layerHeight) / 2),
  };
}

async function main(): Promise<void> {
  fs.mkdirSync(outputDir, { recursive: true });

  for (const card of cards) {
    const background = path.join(backgroundsDir, `${card.slug}-background.png`);
    const screenshot = path.join(repoRoot, card.screenshot);
    const output = path.join(outputDir, `${card.slug}-1600x900.png`);
    if (!fs.existsSync(background)) throw new Error(`Missing background: ${background}`);
    if (!fs.existsSync(screenshot)) throw new Error(`Missing screenshot: ${screenshot}`);

    const phone = await createPhoneLayer(screenshot);
    await sharp(background)
      .resize(width, height, { fit: "cover", position: "center" })
      .composite([
        { input: textPanel(card), left: 0, top: 0 },
        { input: phone.buffer, left: phone.left, top: phone.top },
      ])
      .png()
      .toFile(output);
    console.log(path.relative(repoRoot, output));
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
