# Required observations v1

Normative encoding is canonical UTF-8 JSON. Every root and variant field is required; no implicit defaults exist, unknown fields/kinds fail closed, UUIDs and hashes are lowercase, and all arrays/strings/integers obey schema bounds. Observation order is normative and IDs are unique.

Each discriminated request has exact fields: ordered candidate occupancy, a bounded frozen-template request and native capability reference, bounded required existing-note identity, or ordered staged-asset IDs. Native resolves one complete snapshot for the correlated request/preparation revision. Native capabilities are references only; bytes and storage handles never appear here. Empty observations means no native facts are required.
