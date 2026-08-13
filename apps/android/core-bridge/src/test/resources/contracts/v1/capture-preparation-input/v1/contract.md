# Capture preparation input v1

Normative JSON is UTF-8 and schema-conformant. All fields are required; a fact that may be absent uses explicit JSON `null`. Unknown fields and enum values fail with a typed code and safe JSON path. UUID/SHA strings are lowercase. Integers use JSON decimal notation and the schema bounds. Arrays preserve order and are bounded by the schema; no default is implicit.

The request freezes source/timezone/calendar/locale, operation and all core/renderer/profile pins, ordered discriminated text/link/asset payloads, complete preset/destination/route/metadata policy, and invocation/location outcome. Each payload variant admits exactly its own fields. Logical paths are relative segment arrays. Storage handles, provider IDs, bookmarks, URIs, template bytes, and existing-note bytes are forbidden. Retry marker policy preserves `<!-- vox-capture:<lowercase-uuid> -->` semantics.
