# Required observations v1

This versioned output is an ordered bounded request list produced by preparation. `contractVersion` is exactly `1`; unknown versions/fields fail closed. Every observation has a lowercase UUID, typed kind, required flag, and optional byte ceiling. Native code resolves each request once against its own storage capabilities. Rust never calls storage through FFI.

Supported kinds are candidate occupancy, frozen template bytes/hash, existing-note bytes/hash, and staged-asset metadata. Absence is explicit in the corresponding materialization result. Requests correlate the request ID, preparation revision, and snapshot hash so results from another attempt cannot be mixed. No platform handle, user path, bookmark, URI, or document ID is permitted.
