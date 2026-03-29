# Prompt: NanoClaw App Store Connect Review Monitor

## Goal

Set up NanoClaw (a lightweight Claude agent platform) to automatically monitor my iOS app's App Store review status and notify me via messaging when the status changes. When the app is rejected, the agent should use a headless browser (Playwright) to navigate App Store Connect, read the full rejection comments from the Resolution Center, and send me the complete details.

## My Setup

- **macOS** (Apple Silicon)
- **Claude Code** installed and working (I have a Claude subscription)
- **Node.js 20+** installed
- **Docker** installed and running
- **App details:**
  - App name: Voxboard
  - Bundle ID: `bontecou.Voxboard`
  - Team ID: `67KC823C9A`
  - App Store Connect API Key ID: `DY7NA59TDP`
  - Issuer ID: `6c3b3640-c6bf-40a9-b6e5-57cda2c7776e`
  - API Key file: `/Users/codybontecou/Downloads/AuthKey_DY7NA59TDP.p8`

## Step-by-Step Plan

### Phase 1 — Set Up NanoClaw

1. Fork and clone NanoClaw:
   ```bash
   gh repo fork qwibitai/nanoclaw --clone
   cd nanoclaw
   ```
2. Run `claude` and then `/setup` inside Claude Code to complete the guided setup
3. Add a messaging channel. I want WhatsApp. Run `/add-whatsapp` and follow the setup flow. If WhatsApp is problematic, fall back to Telegram (`/add-telegram`) or Discord (`/add-discord`).
4. Verify the basic NanoClaw agent works — I can send a message and get a response.

### Phase 2 — App Store Connect API Polling

Build a script that the NanoClaw agent can run inside its container to check review status via the App Store Connect API.

The script should:

1. **Generate a JWT** from my `.p8` API key using the `jsonwebtoken` npm package:
   - Algorithm: ES256
   - Issuer: `6c3b3640-c6bf-40a9-b6e5-57cda2c7776e`
   - Key ID: `DY7NA59TDP`
   - Audience: `appstoreconnect-v1`
   - Expiry: 20 minutes
2. **Look up the app ID** via `GET /v1/apps?filter[bundleId]=bontecou.Voxboard`
3. **Get the latest version status** via `GET /v1/apps/{appId}/appStoreVersions?limit=1&sort=-createdDate`
4. **Read and persist the last known state** to a local JSON file (e.g., `last-status.json`)
5. **Return a structured result** indicating whether the status changed and what the new status is

Key API states to track:
- `WAITING_FOR_REVIEW`
- `IN_REVIEW`
- `REJECTED`
- `PENDING_DEVELOPER_RELEASE`
- `READY_FOR_DISTRIBUTION`
- `PREPARE_FOR_SUBMISSION`

Mount the API key file read-only into the container at `/mnt/keys/AuthKey.p8`.

### Phase 3 — Playwright Browser Automation for Resolution Center

When the API polling detects a `REJECTED` status, the agent should use Playwright to:

1. **Launch headless Chromium** with a persistent browser context (stored in the container's filesystem so sessions survive between runs)
2. **Navigate to App Store Connect** (`https://appstoreconnect.apple.com`)
3. **Handle authentication:**
   - If an existing session is valid, proceed directly
   - If login is required, enter Apple ID credentials (store in `.env` or prompt me)
   - If 2FA is triggered, **message me via the messaging channel** asking for the code, wait for my reply, then enter it
   - Save the authenticated session/cookies for reuse
4. **Navigate to the app's Resolution Center:**
   - Go to My Apps → Voxboard → App Review / Resolution Center
   - Or directly to `https://appstoreconnect.apple.com/apps/<APP_ID>/resolution-center`
5. **Extract the rejection details:**
   - All guideline citations (e.g., "Guideline 2.3.7")
   - The full rejection message text
   - Any "Next Steps" instructions
   - The review date and device used
6. **Take a screenshot** of the Resolution Center page
7. **Return all extracted data** so the agent can format and send it to me

Important Playwright notes:
- Install Chromium inside the container: `npx playwright install chromium --with-deps`
- Use a persistent context (`launchPersistentContext`) so cookies survive between runs
- Store the browser profile at a mounted path so it persists across container restarts
- Handle ASC's SPA navigation — wait for network idle and specific selectors rather than relying on URLs
- Add reasonable timeouts and error handling — if ASC changes their UI, fail gracefully and message me that manual checking is needed

### Phase 4 — Scheduled Task

Set up a NanoClaw scheduled task that:

1. **Runs every 30 minutes** during business hours (8am–10pm), or every 30 minutes always — I'm fine with either
2. **Calls the API polling script** first (lightweight check)
3. **If status changed:**
   - If `REJECTED` → run the Playwright script to get full rejection details, then message me with everything
   - If `IN_REVIEW` → message me: "Voxboard is now being reviewed"
   - If `READY_FOR_DISTRIBUTION` or `PENDING_DEVELOPER_RELEASE` → message me: "🎉 Voxboard has been approved!"
   - For any other state change → message me the old and new states
4. **If status unchanged:** do nothing (no message)

Tell the agent via the main channel, something like:
> @Andy every 30 minutes, run the App Store review status check for Voxboard. Only message me if something changed. If rejected, use the browser to get the full rejection details from the Resolution Center.

### Phase 5 — Testing

1. Test the API polling script standalone — verify it can authenticate and read the current version status
2. Test the Playwright ASC login flow — verify it can navigate to the app page (I'll handle 2FA interactively the first time)
3. Test the scheduled task — trigger it manually and verify the message comes through
4. Verify session persistence — confirm the browser session survives between polling runs

## File Structure

I'd expect something like this inside the NanoClaw project:

```
nanoclaw/
├── groups/
│   └── asc-monitor/
│       ├── CLAUDE.md          # Agent memory for this group
│       ├── last-status.json   # Persisted last known review state
│       └── browser-data/      # Playwright persistent context
├── scripts/
│   └── asc/
│       ├── poll-status.mjs    # API polling script
│       ├── read-rejection.mjs # Playwright Resolution Center scraper
│       └── generate-jwt.mjs   # JWT generation utility
└── ...
```

## Error Handling

- If the API key is invalid or expired → message me to update it
- If the browser session expires → message me asking to re-authenticate, then handle 2FA interactively
- If ASC's UI has changed and selectors fail → message me that the scraper needs updating, fall back to just reporting the status change from the API
- If the container can't reach the internet → log the error and retry next cycle

## What Success Looks Like

I submit a build to App Store Connect, and without touching ASC myself, I get messages like:

- "⏳ Voxboard is now IN_REVIEW"
- "🎉 Voxboard has been APPROVED! Status: PENDING_DEVELOPER_RELEASE"
- Or the big one: "🔴 Voxboard was REJECTED. Here are the full reviewer comments: [complete text of all guideline issues, next steps, review device, etc.] [screenshot attached]"
