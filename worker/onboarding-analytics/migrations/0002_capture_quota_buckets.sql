-- Privacy-safe, coarse successful-Capture allowance buckets.
-- Never store request IDs, captured content, filenames, destinations, or raw counts.

ALTER TABLE onboarding_events ADD COLUMN free_captures_used_bucket TEXT;
ALTER TABLE onboarding_events ADD COLUMN free_captures_remaining_bucket TEXT;
