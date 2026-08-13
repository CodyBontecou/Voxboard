# Capture materialization input v1

Normative encoding is canonical UTF-8 JSON. All fields are required; nullable fields encode absence explicitly, unknown fields/kinds fail closed, and no defaults are inferred. UUID/hash casing, integer/string/array bounds, order, and exact tagged variants are schema normative.

This repeats every deterministic preparation fact (source, time/calendar/locale, operation, pins, complete frozen preset/destination/route/metadata policy, ordered payloads) and adds the correlated preparation revision/hash plus every exact observation result. Candidate occupancy, template presence/stream/length/hash, existing note identity/stream/length/hash, and ordered staged assets cannot be mixed between attempts. Control JSON is at most 1 MiB; streamed input chunks are at most 1 MiB and note/template aggregate is at most 256 MiB. One ordered input, seal, and finalize are allowed; incomplete/cancelled/duplicate/out-of-order/post-terminal sessions produce no plan.
