# App Store Connect Setup Prompt for Claude (Computer Use)

Copy everything below the `---` line and paste it into Claude with computer use enabled.

---

You are going to set up an iOS app called **Voxboard** in App Store Connect by clicking through the UI yourself. Do NOT describe steps or give instructions — actually navigate, click, type, and fill in every field. After each action, take a screenshot to confirm what happened before moving on.

## Step 0 — Sign In

1. Open https://appstoreconnect.apple.com
2. If not signed in, sign in with Apple ID credentials. Wait for the dashboard to fully load.
3. Click **Apps**.

## Step 1 — Create the App

If an app named "Voxboard" already exists in the app list, click it and skip to Step 2.

Otherwise:

1. Click the **+** button near the top-left → **New App**
2. Fill in the dialog:
   - **Platforms:** check **iOS** only
   - **Name:** `Voxboard`
   - **Primary Language:** `English (U.S.)`
   - **Bundle ID:** select `bontecou.Voxboard` from the dropdown (it is already registered in the developer portal)
   - **SKU:** `bontecou.Voxboard`
   - Leave "Full Access" user access selected (the default)
3. Click **Create**
4. Wait for the app page to load.

## Step 2 — App Information

Click **App Information** in the left sidebar. Fill in:

- **Subtitle:** `Voice-to-Text Keyboard — On-Device AI`
- **Primary Category:** `Utilities`
- **Secondary Category:** `Productivity`
- Scroll down to **Content Rights** → click **Edit** (or the disclosure) → select **"This app does not contain, show, or access third-party content"** → click **Done** / **Save**

Click **Save** at the top-right of the App Information page.

## Step 3 — Pricing and Availability

Click **Pricing and Availability** (or **Distribution** → **Pricing**) in the left sidebar.

- **Price Schedule:** set the base price to **Free** ($0.00 / Tier 0)
- **Availability:** ensure it is available in **all territories** (this should be the default)

Click **Save**.

## Step 4 — App Privacy

Click **App Privacy** in the left sidebar.

1. Click **Get Started** (or **Edit** if already started)
2. When asked "Do you or your third-party partners collect data from this app?" → select **No, we do not collect data from this app**
3. Confirm / Save / Publish the privacy responses

This is accurate: Voxboard runs whisper.cpp entirely on-device. No audio, transcripts, keystrokes, or personal data ever leave the device. There are no analytics, accounts, or network requests (except optional model downloads from Hugging Face).

## Step 5 — Version 1.0 Metadata

Navigate to the version page. In the left sidebar under the iOS app, there should be a version like **"1.0 Prepare for Submission"** or similar. Click it.

### 5a — Screenshots (6.5-Inch Display)

Scroll to the **App Previews and Screenshots** section. Select the **6.5-Inch Display** size class (iPhone 14 Plus / 15 Plus / etc.).

Upload these 5 screenshot files **in this exact order**. They are on the local filesystem — drag or upload them one at a time:

1. `/Users/codybontecou/dev/Voxboard/output/appstore-slide-1.png`
2. `/Users/codybontecou/dev/Voxboard/output/appstore-slide-2.png`
3. `/Users/codybontecou/dev/Voxboard/output/appstore-slide-3.png`
4. `/Users/codybontecou/dev/Voxboard/output/appstore-slide-4.png`
5. `/Users/codybontecou/dev/Voxboard/output/appstore-slide-5.png`

All are 1242×2688 PNG (the correct 6.5-inch format).

If App Store Connect offers to reuse these screenshots for other display sizes (6.7", 6.1", 5.5", etc.), accept that.

### 5b — Description & Metadata Fields

Scroll down and fill in these fields exactly:

**Promotional Text:**
```
On-device voice transcription powered by Whisper AI. No internet. No data collection. Just your voice, instantly converted to text.
```

**Description:**
```
Voxboard turns your voice into text — entirely on your device. Powered by whisper.cpp, it delivers fast, accurate speech-to-text without ever sending your audio to the cloud.

CUSTOM KEYBOARD
Install the Voxboard keyboard and transcribe your voice in any app — Safari, Notes, Messages, and more. Tap the microphone, speak, and watch your words appear.

ALWAYS-ON LISTENING
Start listening once in the app, then switch to whatever you're doing. The keyboard controls recording — tap Start to capture a segment, tap Stop to transcribe. No need to keep the app open.

CHOOSE YOUR MODEL
Pick from 5 Whisper AI models ranging from 75 MB (Tiny — fast and light) to 1.6 GB (Large — maximum accuracy). Download only what you need.

COMPLETE PRIVACY
All speech processing happens on your iPhone using whisper.cpp. No audio recordings, transcripts, or personal data ever leave your device. No accounts. No analytics. No internet connection required.

FEATURES
• Custom iOS keyboard with voice transcription
• Always-on background listening mode
• 5 Whisper model sizes (Tiny through Large)
• Transcript history with copy and search
• 99 language support
• Pre-roll capture (catches words spoken just before you hit record)
• Real-time audio level visualization
• Dark mode UI
```

**Keywords:**
```
voice,transcription,speech,text,keyboard,whisper,dictation,offline,private,AI
```

**Support URL:**
```
https://bontecou.com
```

**Marketing URL:** leave blank

**Version:** should already say `1.0` — if not, type `1.0`

**Copyright:**
```
2026 Cody Bontecou
```

**What's New in This Version:**
```
Initial release.
```

### 5c — General App Information (on the version page)

If there is an **Age Rating** section or link on this page:

1. Click it → fill out the questionnaire
2. Answer **"None"** or **"No"** or **"Infrequent/Mild: None"** to every single question (violence, gambling, drugs, alcohol, sexual content, profanity, horror, contests, unrestricted web access, etc.)
3. This app has absolutely zero objectionable content
4. Save / Done

### 5d — Review Information

Scroll to the **App Review Information** section (near the bottom of the version page).

- **Sign-In Required:** make sure this is **unchecked** / set to **No** (there are no user accounts)
- **Contact Information:**
  - **First Name:** `Cody`
  - **Last Name:** `Bontecou`
  - **Phone Number:** leave whatever is pre-filled, or if blank and required, enter any valid placeholder
  - **Email:** leave whatever is pre-filled, or if blank and required, enter any valid placeholder

- **Notes:**
```
Voxboard is a custom keyboard extension with voice transcription powered by whisper.cpp (on-device ML).

To test the keyboard:
1. Launch the app and grant microphone permission when prompted.
2. Tap "Start Listening" to activate always-on background audio capture.
3. Go to Settings → General → Keyboard → Keyboards → Add New Keyboard → select "Voxboard".
4. Tap the Voxboard keyboard entry → enable "Allow Full Access" (required for microphone access in keyboard extensions).
5. Open any text field (e.g., Notes app), switch to the Voxboard keyboard using the globe icon.
6. Tap the Record button on the keyboard toolbar, speak, then tap Stop. Your speech will be transcribed and inserted as text.

The app ships with the Whisper "Base" model (142 MB) bundled. Additional models can be downloaded from Settings within the app. All processing is done on-device — the app makes no network requests except when downloading optional additional Whisper models from Hugging Face.

The keyboard extension requires "Allow Full Access" solely for microphone access (NSMicrophoneUsageDescription). No keystrokes or user data are collected or transmitted.
```

### 5e — Build

If a build is already available in the **Build** section, select the most recent one. If no builds appear, leave this empty — I will upload the build separately.

### 5f — Release Options

Scroll to **Version Release** (or **Release Options**) at the bottom:

- Select **"Automatically release this version"** after App Review approval

### 5g — Save

Click **Save** at the top-right of the version page. Confirm the save completed successfully.

## Step 6 — Final Verification

After saving everything, do a quick pass:

1. Click **App Information** → verify subtitle, categories, and content rights are saved
2. Click **Pricing and Availability** → verify price is Free
3. Click **App Privacy** → verify it says "No data collected"
4. Click back to the **1.0 Prepare for Submission** version → verify screenshots, description, keywords, review notes are all present

Take a final screenshot showing the version page so I can confirm everything looks correct.

## ⚠️ IMPORTANT: Do NOT click "Submit for Review"

Fill in everything and save, but do **not** submit. I want to review it all manually before submitting.

## Quick Reference

| Field | Value |
|---|---|
| App Name | Voxboard |
| Bundle ID | bontecou.Voxboard |
| SKU | bontecou.Voxboard |
| Primary Language | English (U.S.) |
| Subtitle | Voice-to-Text Keyboard — On-Device AI |
| Primary Category | Utilities |
| Secondary Category | Productivity |
| Price | Free |
| Privacy | No data collected |
| Copyright | 2026 Cody Bontecou |
| Support URL | https://bontecou.com |
| Version | 1.0 |
| Team ID | 67KC823C9A |
| Deployment Target | iOS 17.6 |
| Platforms | iPhone + iPad |
