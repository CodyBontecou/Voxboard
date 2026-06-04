import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.ts";

const installId = "00000000-0000-4000-8000-000000000001";

class FakeD1Database {
  preparedSql = "";
  statements = [];

  prepare(sql) {
    this.preparedSql = sql;
    return {
      bind: (...values) => ({ values }),
    };
  }

  async batch(statements) {
    this.statements = statements;
    return statements.map(() => ({ success: true }));
  }
}

async function postEvents(body, env = {}) {
  const db = new FakeD1Database();
  const request = new Request("https://voxboard-onboarding.example/v1/events", {
    method: "POST",
    headers: { "content-type": "application/json", ...(env.headers ?? {}) },
    body: JSON.stringify(body),
  });

  const response = await worker.fetch(request, { DB: db, ...env.bindings });
  const json = await response.json();
  return { db, response, json };
}

function baseProperties(extra = {}) {
  return {
    experimentId: "voxboard_onboarding_activation",
    variantId: "baseline_v1",
    platform: "ios",
    appVersion: "1.7.0",
    buildNumber: "123",
    ...extra,
  };
}

test("accepts onboarding events and stores coarse columns", async () => {
  const events = [
    ["00000000-0000-4000-8000-000000000101", "onboarding_started", "welcome"],
    ["00000000-0000-4000-8000-000000000102", "onboarding_step_viewed", "microphone_access"],
    ["00000000-0000-4000-8000-000000000103", "onboarding_model_setup_completed", "model_setup"],
    ["00000000-0000-4000-8000-000000000104", "onboarding_completed", "ready"],
  ].map(([eventId, eventName, onboardingStep]) => ({
    eventId,
    eventName,
    properties: baseProperties({
      onboardingStep,
      permissionStatus: onboardingStep === "microphone_access" ? "granted" : undefined,
      modelEngine: onboardingStep === "model_setup" ? "whisper" : undefined,
      modelSizeBucket: onboardingStep === "model_setup" ? "bundled" : undefined,
      freeMinutesUsedBucket: "0_5_min",
      freeMinutesRemainingBucket: "5_15_min",
    }),
  }));

  const { db, response, json } = await postEvents({ installId, events });

  assert.equal(response.status, 200);
  assert.deepEqual(json, { ok: true, accepted: events.length });
  assert.match(db.preparedSql, /onboarding_step/);
  assert.equal(db.statements.length, events.length);

  const payloadJson = db.statements[2].values.at(-1);
  assert.equal(JSON.parse(payloadJson).properties.modelSizeBucket, "bundled");
});

test("rejects onboardingStep values outside the coarse allowlist", async () => {
  const { response, json } = await postEvents({
    installId,
    eventId: "00000000-0000-4000-8000-000000000201",
    eventName: "onboarding_step_viewed",
    properties: baseProperties({ onboardingStep: "folder:/Users/cody/Documents" }),
  });

  assert.equal(response.status, 400);
  assert.equal(json.error, "unknown_property_value:onboardingStep");
});

test("rejects unknown properties that could contain user text", async () => {
  const { response, json } = await postEvents({
    installId,
    eventId: "00000000-0000-4000-8000-000000000202",
    eventName: "onboarding_completed",
    properties: baseProperties({ transcriptText: "hello world" }),
  });

  assert.equal(response.status, 400);
  assert.equal(json.error, "unknown_property:transcriptText");
});

test("accepts paywall context on purchase events", async () => {
  const { db, response, json } = await postEvents({
    installId,
    eventId: "00000000-0000-4000-8000-000000000301",
    eventName: "onboarding_purchase_finished",
    properties: baseProperties({
      onboardingStep: "unlock",
      paywallContext: "settings",
      productId: "bontecou.Voxboard.unlock",
      purchaseOutcome: "succeeded",
      freeMinutesUsedBucket: "15_plus_min",
      freeMinutesRemainingBucket: "0",
    }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(json, { ok: true, accepted: 1 });

  const payload = JSON.parse(db.statements[0].values.at(-1));
  assert.equal(payload.eventName, "onboarding_purchase_finished");
  assert.equal(payload.properties.paywallContext, "settings");
});

test("honors optional bearer token", async () => {
  const body = {
    installId,
    eventId: "00000000-0000-4000-8000-000000000401",
    eventName: "onboarding_started",
    properties: baseProperties({ onboardingStep: "welcome" }),
  };

  const unauthorized = await postEvents(body, { bindings: { INGEST_TOKEN: "secret" } });
  assert.equal(unauthorized.response.status, 401);

  const authorized = await postEvents(body, {
    bindings: { INGEST_TOKEN: "secret" },
    headers: { authorization: "Bearer secret" },
  });
  assert.equal(authorized.response.status, 200);
});
