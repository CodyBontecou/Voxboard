#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const __filename = fileURLToPath(import.meta.url);
const toolDir = path.dirname(__filename);
const repoRoot = path.resolve(toolDir, "../..");
const sourceBackground = path.join(
  repoRoot,
  "app-store-output/reddit/backgrounds/03-transcription-stays-local-background.png",
);
const readyPath = path.join(repoRoot, "app-store-input/screenshots/04-watch-ready.png");
const recordingPath = path.join(repoRoot, "app-store-input/screenshots/05-watch-recording.png");
const finalPath = path.join(
  repoRoot,
  "app-store-output/reddit/final-landscape/04-apple-watch-experience-1600x900.png",
);
const manifestPath = path.join(repoRoot, "app-store-output/reddit/watch-brand-aligned-manifest.json");
const blue = "#54A2FF";
const lightBlue = "#8FA8FF";

function copyOverlay(): Buffer {
  return Buffer.from(`
    <svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect x="54" y="54" width="790" height="792" rx="54" fill="#11110F" opacity="0.90"/>
      <rect x="118" y="118" width="86" height="9" rx="4.5" fill="${blue}"/>
      <text x="118" y="173" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="25" font-weight="700" letter-spacing="5" fill="${blue}">VOX.MD</text>
      <text x="118" y="265" font-family="Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="82" font-weight="700" letter-spacing="-3" fill="#F7F7F3">Record from</text>
      <text x="118" y="357" font-family="Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="82" font-weight="700" letter-spacing="-3" fill="#F7F7F3">your wrist</text>
      <text x="122" y="500" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="31" font-weight="500" fill="#F7F7F3" opacity="0.88">Start, pause, and save</text>
      <text x="122" y="546" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="31" font-weight="500" fill="#F7F7F3" opacity="0.88">without reaching for iPhone</text>
      <text x="122" y="772" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="24" font-weight="600" letter-spacing="1" fill="#F7F7F3" opacity="0.60">vox.isolated.tech</text>
    </svg>
  `);
}

async function watchLayer(screenshotPath: string, targetWidth: number, accent: string): Promise<Buffer> {
  const metadata = await sharp(screenshotPath).metadata();
  if (!metadata.width || !metadata.height) throw new Error(`Could not inspect ${screenshotPath}`);
  const targetHeight = Math.round(targetWidth * (metadata.height / metadata.width));
  const border = 14;
  const shadow = 26;
  const layerWidth = targetWidth + border * 2 + shadow * 2;
  const layerHeight = targetHeight + border * 2 + shadow * 2;
  const radius = Math.round(targetWidth * 0.16);
  const resized = await sharp(screenshotPath)
    .resize(targetWidth, targetHeight, { fit: "contain" })
    .png()
    .toBuffer();
  const mask = Buffer.from(`
    <svg width="${targetWidth}" height="${targetHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${targetWidth}" height="${targetHeight}" rx="${radius}" fill="#fff"/>
    </svg>
  `);
  const screen = await sharp(resized)
    .composite([{ input: mask, blend: "dest-in" }])
    .png()
    .toBuffer();
  const frame = Buffer.from(`
    <svg width="${layerWidth}" height="${layerHeight}" xmlns="http://www.w3.org/2000/svg">
      <rect x="${shadow + 8}" y="${shadow + 14}" width="${targetWidth + border * 2}" height="${targetHeight + border * 2}" rx="${radius + border}" fill="#000" opacity="0.34"/>
      <rect x="${shadow}" y="${shadow}" width="${targetWidth + border * 2}" height="${targetHeight + border * 2}" rx="${radius + border}" fill="#101010" stroke="${accent}" stroke-width="3"/>
    </svg>
  `);
  return sharp(frame)
    .composite([{ input: screen, left: shadow + border, top: shadow + border }])
    .png()
    .toBuffer();
}

async function main(): Promise<void> {
  for (const file of [sourceBackground, readyPath, recordingPath]) {
    if (!fs.existsSync(file)) throw new Error(`Missing input: ${file}`);
  }

  const ready = await watchLayer(readyPath, 330, lightBlue);
  const recording = await watchLayer(recordingPath, 380, blue);
  await sharp(sourceBackground)
    .resize(1600, 900, { fit: "cover", position: "center" })
    .composite([
      { input: copyOverlay(), left: 0, top: 0 },
      { input: ready, left: 870, top: 80 },
      { input: recording, left: 1135, top: 300 },
    ])
    .png()
    .toFile(finalPath);

  fs.writeFileSync(
    manifestPath,
    `${JSON.stringify(
      {
        timestamp: new Date().toISOString(),
        campaign: "Vox.md Reddit Apple Watch brand-aligned revision",
        provider: "local-recompose",
        paidThisRun: false,
        outputDimensions: { width: 1600, height: 900, label: "Reddit landscape 16:9" },
        backgroundSource: "app-store-output/reddit/backgrounds/03-transcription-stays-local-background.png",
        screenshotsSentToOpenAI: false,
        screenshots: [
          "app-store-input/screenshots/04-watch-ready.png",
          "app-store-input/screenshots/05-watch-recording.png",
        ],
        finalFile: "app-store-output/reddit/final-landscape/04-apple-watch-experience-1600x900.png",
        palette: {
          panel: "#11110F",
          primaryAccent: blue,
          secondaryAccent: lightBlue,
        },
      },
      null,
      2,
    )}\n`,
  );
  console.log(path.relative(repoRoot, finalPath));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
