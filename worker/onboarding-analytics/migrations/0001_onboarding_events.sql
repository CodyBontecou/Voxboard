-- Voxboard privacy-safe onboarding analytics event store.
-- Deliberately stores only validated, coarse onboarding/activation fields.
-- Do not add audio, recordings, transcript text, dictated text, keystrokes,
-- file/folder paths, custom template text, model paths, raw request IPs,
-- user agents, raw device identifiers, or user-entered content.

CREATE TABLE IF NOT EXISTS onboarding_events (
  id TEXT PRIMARY KEY,
  received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  install_id TEXT NOT NULL,
  event_name TEXT NOT NULL,
  experiment_id TEXT,
  variant_id TEXT,
  app_version TEXT,
  build_number TEXT,
  platform TEXT,
  onboarding_step TEXT,
  permission_status TEXT,
  model_engine TEXT,
  model_size_bucket TEXT,
  file_export_format TEXT,
  file_export_mode TEXT,
  free_minutes_used_bucket TEXT,
  free_minutes_remaining_bucket TEXT,
  paywall_context TEXT,
  product_id TEXT,
  purchase_outcome TEXT,
  error_category TEXT,
  payload_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_onboarding_events_received_at
  ON onboarding_events(received_at);

CREATE INDEX IF NOT EXISTS idx_onboarding_events_event_received
  ON onboarding_events(event_name, received_at);

CREATE INDEX IF NOT EXISTS idx_onboarding_events_variant_received
  ON onboarding_events(variant_id, received_at);

CREATE INDEX IF NOT EXISTS idx_onboarding_events_install_event_received
  ON onboarding_events(install_id, event_name, received_at);

CREATE INDEX IF NOT EXISTS idx_onboarding_events_step_received
  ON onboarding_events(onboarding_step, received_at);
