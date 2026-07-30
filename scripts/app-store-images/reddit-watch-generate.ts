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
const backgroundPath = path.join(outputDir, "backgrounds/04-apple-watch-experience-background.png");
const finalPath = path.join(outputDir, "final-landscape/04-apple-watch-experience-1600x900.png");
const readyPath = path.join(repoRoot, "app-store-input/screenshots/04-watch-ready.png");
const recordingPath = path.join(repoRoot, "app-store-input/screenshots/05-watch-recording.png");
const model = "gpt-image-2";
const quality = "medium";
const aiSize = "1536x1024";
const generate = process.argv.includes("--generate");
const force = process.argv.includes("--force");

const prompt = [
  "Abstract landscape marketing background for Vox.md on Apple Watch, a local-first voice capture app.",
  "Deep graphite and black background with restrained warm red recording pulses, a subtle green saved-state accent, and thin waveform arcs flowing from the right toward the center.",
  "Calm, technical, modern, and precise with soft depth. Keep the left side quiet for a headline and the right side visually simple for two Watch screenshots.",
  "No text, no letters, no numbers, no logos, no Apple logo, no watches, no devices, no app interfaces, no screens, no hands, no people, no cloud imagery.",
].join(" ");

dotenv.config({ path: path.join(repoRoot, ".env"), override: false });
dotenv.config({ path: path.join(toolDir, ".env"), override: false });

function getApiKey(required: boolean): string | undefined {
  if (process.env.OPENAI_API_KEY?.trim()) return process.env.OPENAI_API_KEY.trim();
  try {
    const key = execFileSync(
      "security",
      ["find-generic-password", "-a", "default", "-s", "appstore-ai-images.openai-api-key", "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (key) return key;
  } catch {
    // Missing or locked Keychain item. The caller emits a bounded error.
  }
  if (required) throw new Error("OpenAI credential missing from the environment and macOS Keychain.");
  return undefined;
}

function credentialSource(): "env" | "keychain" | "missing" {
  if (process.env.OPENAI_API_KEY?.trim()) return "env";
  return getApiKey(false) ? "keychain" : "missing";
}

async function generateBackground(client: OpenAI): Promise<Buffer> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await client.images.generate({
        model,
        quality,
        size: aiSize,
        n: 1,
        prompt,
      });
      const image = response.data?.[0];
      if (image?.b64_json) return Buffer.from(image.b64_json, "base64");
      if (image?.url) {
        const download = await fetch(image.url);
        if (!download.ok) throw new Error(`Image download failed with HTTP ${download.status}.`);
        return Buffer.from(await download.arrayBuffer());
      }
      throw new Error("OpenAI returned no image data.");
    } catch (error) {
      lastError = error;
      if (attempt === 0) console.warn("Background generation failed; retrying once.");
    }
  }
  throw new Error(`Background generation failed: ${lastError instanceof Error ? lastError.message : String(lastError)}`);
}

function copyOverlay(): Buffer {
  return Buffer.from(`
    <svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect x="54" y="54" width="790" height="792" rx="54" fill="#11110F" opacity="0.90"/>
      <rect x="118" y="118" width="86" height="9" rx="4.5" fill="#FF5362"/>
      <text x="118" y="173" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="25" font-weight="700" letter-spacing="5" fill="#FF5362">VOX.MD</text>
      <text x="118" y="265" font-family="Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="82" font-weight="700" letter-spacing="-3" fill="#F7F7F3">Record from</text>
      <text x="118" y="357" font-family="Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" font-size="82" font-weight="700" letter-spacing="-3" fill="#F7F7F3">your wrist</text>
      <text x="122" y="500" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="31" font-weight="500" fill="#F7F7F3" opacity="0.88">Start, pause, and save</text>
      <text x="122" y="546" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="31" font-weight="500" fill="#F7F7F3" opacity="0.88">without reaching for iPhone</text>
      <text x="122" y="772" font-family="Geist Mono, ui-monospace, 'SFMono-Regular', monospace" font-size="24" font-weight="600" letter-spacing="1" fill="#F7F7F3" opacity="0.60">vox.isolated.tech</text>
    </svg>
  `);
}

async function watchLayer(
  screenshotPath: string,
  targetWidth: number,
  accent: string,
): Promise<Buffer> {
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

async function compositeFinal(): Promise<void> {
  const ready = await watchLayer(readyPath, 330, "#2BD967");
  const recording = await watchLayer(recordingPath, 380, "#FF5362");
  fs.mkdirSync(path.dirname(finalPath), { recursive: true });
  await sharp(backgroundPath)
    .resize(1600, 900, { fit: "cover", position: "center" })
    .composite([
      { input: copyOverlay(), left: 0, top: 0 },
      { input: ready, left: 870, top: 80 },
      { input: recording, left: 1135, top: 300 },
    ])
    .png()
    .toFile(finalPath);
}

function writeManifest(paid: boolean): void {
  const manifestPath = path.join(outputDir, "watch-manifest.json");
  fs.writeFileSync(
    manifestPath,
    `${JSON.stringify(
      {
        timestamp: new Date().toISOString(),
        campaign: "Vox.md Reddit Apple Watch experience",
        provider: "openai-direct",
        model,
        quality,
        credentialSource: credentialSource(),
        paid,
        plannedImageGenerations: 1,
        aiBackgroundSize: aiSize,
        outputDimensions: { width: 1600, height: 900, label: "Reddit landscape 16:9" },
        screenshotsSentToOpenAI: false,
        screenshots: [
          "app-store-input/screenshots/04-watch-ready.png",
          "app-store-input/screenshots/05-watch-recording.png",
        ],
        prompt,
        filesCreated: paid
          ? [
              "app-store-output/reddit/backgrounds/04-apple-watch-experience-background.png",
              "app-store-output/reddit/final-landscape/04-apple-watch-experience-1600x900.png",
              "app-store-output/reddit/watch-manifest.json",
            ]
          : ["app-store-output/reddit/watch-manifest.json"],
        assumptions: [
          "The Watch screenshots came from a fresh simulator build of the current repository.",
          "OpenAI generated only the abstract background.",
          "The Watch screenshots were composited locally and were not uploaded.",
        ],
      },
      null,
      2,
    )}\n`,
  );
}

async function main(): Promise<void> {
  for (const screenshot of [readyPath, recordingPath]) {
    if (!fs.existsSync(screenshot)) throw new Error(`Missing Watch screenshot: ${screenshot}`);
  }
  fs.mkdirSync(path.dirname(backgroundPath), { recursive: true });
  fs.mkdirSync(path.dirname(finalPath), { recursive: true });

  console.log("Vox.md Apple Watch Reddit card");
  console.log(`Mode: ${generate ? "generate (one paid background call)" : "dry-run"}`);
  console.log(`Model: ${model}; quality: ${quality}; credential: ${credentialSource()}`);
  console.log(`Prompt: ${prompt}`);

  if (!generate) {
    writeManifest(false);
    console.log("Dry run complete. No AI call was made.");
    return;
  }

  if (!force && (fs.existsSync(backgroundPath) || fs.existsSync(finalPath))) {
    throw new Error("Watch outputs already exist. Pass --force to replace them.");
  }
  const client = new OpenAI({ apiKey: getApiKey(true) });
  const background = await generateBackground(client);
  fs.writeFileSync(backgroundPath, background);
  await compositeFinal();
  writeManifest(true);
  console.log(path.relative(repoRoot, finalPath));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
