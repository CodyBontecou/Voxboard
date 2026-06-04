export interface Env {
  DB: D1Database;
  INGEST_TOKEN?: string;
  MAX_BATCH_SIZE?: string;
}

type OnboardingValue = string | number;
type OnboardingProperties = Record<string, OnboardingValue>;

type OnboardingEventRow = {
  id: string;
  installId: string;
  eventName: string;
  properties: OnboardingProperties;
};

const MAX_BODY_BYTES = 64 * 1024;
const DEFAULT_MAX_BATCH_SIZE = 50;

const EVENT_NAMES = new Set([
  "onboarding_started",
  "onboarding_step_viewed",
  "onboarding_microphone_permission_completed",
  "onboarding_model_setup_completed",
  "onboarding_keyboard_setup_started",
  "onboarding_keyboard_setup_completed",
  "onboarding_file_export_setup_completed",
  "onboarding_paywall_shown",
  "onboarding_purchase_started",
  "onboarding_purchase_finished",
  "onboarding_restore_started",
  "onboarding_restore_finished",
  "onboarding_completed",
]);

const STRING_PROPERTY_KEYS = new Set([
  "experimentId",
  "variantId",
  "appVersion",
  "buildNumber",
  "platform",
  "onboardingStep",
  "permissionStatus",
  "modelEngine",
  "modelSizeBucket",
  "fileExportFormat",
  "fileExportMode",
  "freeMinutesUsedBucket",
  "freeMinutesRemainingBucket",
  "paywallContext",
  "productId",
  "purchaseOutcome",
  "errorCategory",
]);

const ALLOWED_PROPERTY_KEYS = new Set([...STRING_PROPERTY_KEYS]);

const KNOWN_EXPERIMENT_IDS = new Set(["voxboard_onboarding_activation"]);
const KNOWN_VARIANT_IDS = new Set(["baseline_v1"]);
const PLATFORMS = new Set(["ios", "macos"]);
const ONBOARDING_STEPS = new Set([
  "welcome",
  "microphone_access",
  "model_setup",
  "keyboard_enablement",
  "file_export",
  "unlock",
  "ready",
]);
const PERMISSION_STATUSES = new Set(["granted", "denied", "restricted", "unavailable", "unknown"]);
const MODEL_ENGINES = new Set(["whisper", "parakeet", "unknown"]);
const MODEL_SIZE_BUCKETS = new Set(["bundled", "under_100_mb", "100_500_mb", "500_mb_1_gb", "1_gb_plus", "unknown"]);
const FILE_EXPORT_FORMATS = new Set(["txt", "md", "json", "yaml", "disabled", "unknown"]);
const FILE_EXPORT_MODES = new Set(["append", "new_file", "disabled", "unknown"]);
const USAGE_BUCKETS = new Set(["0", "0_5_min", "5_15_min", "15_plus_min", "unlimited", "unknown"]);
const PAYWALL_CONTEXTS = new Set(["onboarding", "usage_meter", "limit", "recording", "keyboard", "widget", "settings", "restore", "unknown"]);
const PRODUCT_IDS = new Set(["bontecou.Voxboard.unlock"]);
const PURCHASE_OUTCOMES = new Set(["started", "succeeded", "failed", "cancelled", "pending"]);
const ERROR_CATEGORIES = new Set([
  "network_unavailable",
  "store_unavailable",
  "user_cancelled",
  "payment_not_allowed",
  "verification_failed",
  "configuration_unavailable",
  "no_model",
  "microphone_denied",
  "not_unlocked",
  "unknown",
]);

const IDENTIFIER_RE = /^[a-z0-9._-]{1,80}$/;
const APP_VERSION_RE = /^\d+(?:\.\d+){0,3}$/;
const BUILD_NUMBER_RE = /^\d{1,12}$/;
const INSTALL_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const RAW_DATE_PATTERNS = [
  /(?:^|[^0-9])(?:19|20)\d{2}[-_.](?:0[1-9]|1[0-2])[-_.](?:0[1-9]|[12]\d|3[01])(?:$|[^0-9])/,
  /(?:^|[^0-9])(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?:$|[^0-9])/,
];
const SENSITIVE_IDENTIFIER_TOKENS = [
  "audio",
  "recording",
  "transcript",
  "transcription",
  "speech",
  "voice",
  "dictation",
  "keystroke",
  "keyboard_text",
  "folder",
  "file",
  "path",
  "template",
  "documents",
  "desktop",
  "downloads",
  "icloud",
  "email",
  "name",
  "user",
];

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const pathname = normalizedPathname(url.pathname);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (request.method === "GET" && pathname === "/health") {
      return json({ ok: true, service: "voxboard-onboarding-analytics" });
    }

    if (request.method === "POST" && pathname === "/v1/events") {
      return ingestEvents(request, env);
    }

    return json({ ok: false, error: "not_found" }, 404);
  },
};

async function ingestEvents(request: Request, env: Env): Promise<Response> {
  const authError = authorize(request, env);
  if (authError) return authError;

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return json({ ok: false, error: "body_too_large" }, 413);
  }

  const rawBody = await request.text();
  if (new TextEncoder().encode(rawBody).byteLength > MAX_BODY_BYTES) {
    return json({ ok: false, error: "body_too_large" }, 413);
  }

  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  let rows: OnboardingEventRow[];
  try {
    rows = normalizeIngestBody(body, maxBatchSize(env));
  } catch (error) {
    return json({ ok: false, error: error instanceof Error ? error.message : "invalid_payload" }, 400);
  }

  if (rows.length === 0) {
    return json({ ok: false, error: "empty_batch" }, 400);
  }

  const insert = env.DB.prepare(`
    INSERT OR IGNORE INTO onboarding_events (
      id,
      install_id,
      event_name,
      experiment_id,
      variant_id,
      app_version,
      build_number,
      platform,
      onboarding_step,
      permission_status,
      model_engine,
      model_size_bucket,
      file_export_format,
      file_export_mode,
      free_minutes_used_bucket,
      free_minutes_remaining_bucket,
      paywall_context,
      product_id,
      purchase_outcome,
      error_category,
      payload_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  await env.DB.batch(rows.map((row) => insert.bind(
    row.id,
    row.installId,
    row.eventName,
    stringProperty(row.properties, "experimentId"),
    stringProperty(row.properties, "variantId"),
    stringProperty(row.properties, "appVersion"),
    stringProperty(row.properties, "buildNumber"),
    stringProperty(row.properties, "platform"),
    stringProperty(row.properties, "onboardingStep"),
    stringProperty(row.properties, "permissionStatus"),
    stringProperty(row.properties, "modelEngine"),
    stringProperty(row.properties, "modelSizeBucket"),
    stringProperty(row.properties, "fileExportFormat"),
    stringProperty(row.properties, "fileExportMode"),
    stringProperty(row.properties, "freeMinutesUsedBucket"),
    stringProperty(row.properties, "freeMinutesRemainingBucket"),
    stringProperty(row.properties, "paywallContext"),
    stringProperty(row.properties, "productId"),
    stringProperty(row.properties, "purchaseOutcome"),
    stringProperty(row.properties, "errorCategory"),
    JSON.stringify({ eventName: row.eventName, properties: row.properties }),
  )));

  return json({ ok: true, accepted: rows.length });
}

function normalizeIngestBody(body: unknown, maxBatch: number): OnboardingEventRow[] {
  if (!isObject(body)) throw new Error("payload_must_be_object");

  const batchInstallId = optionalString(body.installId);
  const incomingEvents = Array.isArray(body.events) ? body.events : [body];

  if (incomingEvents.length > maxBatch) throw new Error("batch_too_large");

  return incomingEvents.map((event) => normalizeEvent(event, batchInstallId));
}

function normalizeEvent(event: unknown, batchInstallId: string | undefined): OnboardingEventRow {
  if (!isObject(event)) throw new Error("event_must_be_object");

  const eventName = requiredString(event.eventName, "eventName");
  if (!EVENT_NAMES.has(eventName)) throw new Error("unknown_event_name");

  const eventId = validateEventId(optionalString(event.eventId) ?? optionalString(event.id));
  const installId = validateInstallId(optionalString(event.installId) ?? batchInstallId);
  const properties = normalizeProperties(isObject(event.properties) ? event.properties : {});

  return {
    id: eventId,
    installId,
    eventName,
    properties,
  };
}

function normalizeProperties(properties: Record<string, unknown>): OnboardingProperties {
  const normalized: OnboardingProperties = {};

  for (const [key, value] of Object.entries(properties)) {
    if (!ALLOWED_PROPERTY_KEYS.has(key)) throw new Error(`unknown_property:${key}`);
    normalized[key] = validateStringProperty(key, value);
  }

  return normalized;
}

function validateStringProperty(key: string, value: unknown): string {
  if (typeof value !== "string") throw new Error(`invalid_property_type:${key}`);

  switch (key) {
    case "experimentId":
      return validateKnownIdentifier(key, value, KNOWN_EXPERIMENT_IDS);
    case "variantId":
      return validateKnownIdentifier(key, value, KNOWN_VARIANT_IDS);
    case "appVersion":
      if (!APP_VERSION_RE.test(value)) throw new Error(`invalid_property:${key}`);
      return value;
    case "buildNumber":
      if (!BUILD_NUMBER_RE.test(value)) throw new Error(`invalid_property:${key}`);
      return value;
    case "platform":
      return validateSetValue(key, value, PLATFORMS);
    case "onboardingStep":
      return validateSetValue(key, value, ONBOARDING_STEPS);
    case "permissionStatus":
      return validateSetValue(key, value, PERMISSION_STATUSES);
    case "modelEngine":
      return validateSetValue(key, value, MODEL_ENGINES);
    case "modelSizeBucket":
      return validateSetValue(key, value, MODEL_SIZE_BUCKETS);
    case "fileExportFormat":
      return validateSetValue(key, value, FILE_EXPORT_FORMATS);
    case "fileExportMode":
      return validateSetValue(key, value, FILE_EXPORT_MODES);
    case "freeMinutesUsedBucket":
    case "freeMinutesRemainingBucket":
      return validateSetValue(key, value, USAGE_BUCKETS);
    case "paywallContext":
      return validateSetValue(key, value, PAYWALL_CONTEXTS);
    case "productId":
      return validateSetValue(key, value, PRODUCT_IDS);
    case "purchaseOutcome":
      return validateSetValue(key, value, PURCHASE_OUTCOMES);
    case "errorCategory":
      return validateSetValue(key, value, ERROR_CATEGORIES);
    default:
      throw new Error(`unknown_property:${key}`);
  }
}

function validateKnownIdentifier(key: string, value: string, knownValues: Set<string>): string {
  if (!IDENTIFIER_RE.test(value)) throw new Error(`invalid_property:${key}`);
  if (RAW_DATE_PATTERNS.some((pattern) => pattern.test(value))) throw new Error(`invalid_property:${key}`);
  if (containsSensitiveIdentifierToken(value)) throw new Error(`invalid_property:${key}`);
  if (!knownValues.has(value)) throw new Error(`unknown_property_value:${key}`);
  return value;
}

function validateSetValue(key: string, value: string, allowedValues: Set<string>): string {
  if (!allowedValues.has(value)) throw new Error(`unknown_property_value:${key}`);
  return value;
}

function validateEventId(value: string | undefined): string {
  if (!value || !INSTALL_ID_RE.test(value)) throw new Error("invalid_event_id");
  return value.toLowerCase();
}

function validateInstallId(value: string | undefined): string {
  if (!value || !INSTALL_ID_RE.test(value)) throw new Error("invalid_install_id");
  return value.toLowerCase();
}

function containsSensitiveIdentifierToken(value: string): boolean {
  const normalized = value.replace(/[.-]/g, "_").toLowerCase();
  return SENSITIVE_IDENTIFIER_TOKENS.some((token) => normalized.includes(token));
}

function authorize(request: Request, env: Env): Response | undefined {
  if (!env.INGEST_TOKEN) return undefined;

  const expected = `Bearer ${env.INGEST_TOKEN}`;
  if (request.headers.get("authorization") === expected) return undefined;

  return json({ ok: false, error: "unauthorized" }, 401);
}

function maxBatchSize(env: Env): number {
  const parsed = Number(env.MAX_BATCH_SIZE ?? DEFAULT_MAX_BATCH_SIZE);
  return Number.isInteger(parsed) && parsed > 0 ? Math.min(parsed, DEFAULT_MAX_BATCH_SIZE) : DEFAULT_MAX_BATCH_SIZE;
}

function stringProperty(properties: OnboardingProperties, key: string): string | null {
  const value = properties[key];
  return typeof value === "string" ? value : null;
}

function requiredString(value: unknown, key: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`missing_${key}`);
  return value;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: corsHeaders() });
}

function normalizedPathname(pathname: string): string {
  const normalized = pathname.replace(/\/+$/, "");
  return normalized.length > 0 ? normalized : "/";
}

function corsHeaders(): HeadersInit {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "authorization,content-type",
    "cache-control": "no-store",
  };
}
