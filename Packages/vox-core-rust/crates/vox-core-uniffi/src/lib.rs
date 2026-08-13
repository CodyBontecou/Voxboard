#![forbid(unsafe_code)]

//! Thin owned-value `UniFFI` boundary with panic containment and privacy-safe failures.

use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Arc, Mutex},
};

use thiserror::Error;
use vox_core::{DrainedHashes, MaterializationSession};

uniffi::setup_scaffolding!();

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreBuildInfo {
    pub kind: String,
    pub core_api_version: u32,
    pub core_version: String,
    pub source_revision: String,
    pub build_configuration: String,
    pub toolchain_manifest_sha256: String,
    pub supported_operations: Vec<String>,
    pub supported_profile_ids: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreReadiness {
    pub kind: String,
    pub status: String,
    pub session_permitted: bool,
    pub mismatch_codes: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreArtifactDescriptor {
    pub artifact_id: String,
    pub operation_id: String,
    pub stream_id: String,
    pub commit_sequence: u32,
    pub kind: String,
    pub media_type: String,
    pub length: u64,
    pub result_sha256: String,
    pub receipt_kind: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreArtifactDescriptors {
    pub request_id: String,
    pub artifacts: Vec<CoreArtifactDescriptor>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CorePreparedChunk {
    pub artifact_id: String,
    pub stream_id: String,
    pub sequence: u32,
    pub bytes: Vec<u8>,
    pub byte_count: u64,
    pub chunk_sha256: String,
    pub eof: bool,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq, uniffi::Error)]
pub enum VoxCoreError {
    #[error("control input exceeds the size limit")]
    ControlTooLarge,
    #[error("control input is invalid")]
    InvalidControl,
    #[error("control input contains an unknown field")]
    UnknownField,
    #[error("control input is not canonical")]
    NonCanonicalControl,
    #[error("requested compatibility is unsupported")]
    Unsupported,
    #[error("request correlation failed")]
    Correlation,
    #[error("observation stream is invalid")]
    InvalidObservation,
    #[error("session limit was exceeded")]
    LimitExceeded,
    #[error("output verification failed")]
    VerificationFailed,
    #[error("session is terminal")]
    SessionTerminal,
    #[error("session was cancelled")]
    Cancelled,
    #[error("shared core failed internally")]
    InternalPanic,
}

impl From<vox_core::CoreError> for VoxCoreError {
    fn from(value: vox_core::CoreError) -> Self {
        use vox_core::CoreError as Source;
        match value {
            Source::ControlTooLarge => Self::ControlTooLarge,
            Source::InvalidControl
            | Source::StringTooLarge
            | Source::ArrayTooLarge
            | Source::IntegerOutOfRange
            | Source::InvalidEnum
            | Source::InvalidHash
            | Source::InvalidPath
            | Source::InvalidRendering
            | Source::Serialization => Self::InvalidControl,
            Source::UnknownField => Self::UnknownField,
            Source::NonCanonicalControl => Self::NonCanonicalControl,
            Source::UnsupportedCoreApi
            | Source::UnsupportedPreparationInput
            | Source::UnsupportedRequiredObservations
            | Source::UnsupportedMaterializationInput
            | Source::UnsupportedArtifactPlan
            | Source::UnsupportedRenderer
            | Source::UnsupportedProfile
            | Source::UnsupportedOperation
            | Source::UnsupportedModel
            | Source::ToolchainManifestMismatch
            | Source::UnsupportedCollisionSemantics => Self::Unsupported,
            Source::RequestMismatch | Source::SnapshotMismatch | Source::ObservationMismatch => {
                Self::Correlation
            }
            Source::InvalidObservationStream | Source::ObservationSequence | Source::Incomplete => {
                Self::InvalidObservation
            }
            Source::ChunkTooLarge | Source::AggregateTooLarge => Self::LimitExceeded,
            Source::DescriptorMismatch | Source::DrainedHashMismatch => Self::VerificationFailed,
            Source::SessionTerminal => Self::SessionTerminal,
            Source::Cancelled => Self::Cancelled,
        }
    }
}

fn guard<T>(call: impl FnOnce() -> Result<T, VoxCoreError>) -> Result<T, VoxCoreError> {
    // The boundary deliberately suppresses the hook while catching so panic payloads
    // and source locations cannot escape to stderr. Hook replacement/restoration is
    // serialized because the hook is process-global.
    static PANIC_HOOK_LOCK: Mutex<()> = Mutex::new(());
    let _lock = PANIC_HOOK_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = catch_unwind(AssertUnwindSafe(call));
    std::panic::set_hook(previous);
    result.unwrap_or(Err(VoxCoreError::InternalPanic))
}

#[uniffi::export]
pub fn core_build_info() -> Result<CoreBuildInfo, VoxCoreError> {
    guard(|| {
        let value = vox_core::build_info();
        Ok(CoreBuildInfo {
            kind: value.kind.to_owned(),
            core_api_version: value.core_api_version,
            core_version: value.core_version.to_owned(),
            source_revision: value.source_revision.to_owned(),
            build_configuration: value.build_configuration.to_owned(),
            toolchain_manifest_sha256: value.toolchain_manifest_sha256.to_owned(),
            supported_operations: value
                .supported_operations
                .into_iter()
                .map(str::to_owned)
                .collect(),
            supported_profile_ids: value
                .supported_profile_ids
                .into_iter()
                .map(str::to_owned)
                .collect(),
        })
    })
}

#[uniffi::export]
pub fn core_readiness(expected_versions_json: &[u8]) -> Result<CoreReadiness, VoxCoreError> {
    guard(|| {
        vox_core::readiness(expected_versions_json)
            .map(|value| CoreReadiness {
                kind: value.kind.to_owned(),
                status: value.status.to_owned(),
                session_permitted: value.session_permitted,
                mismatch_codes: value
                    .mismatch_codes
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
            })
            .map_err(Into::into)
    })
}

#[uniffi::export]
pub fn core_prepare(preparation_json: &[u8]) -> Result<Vec<u8>, VoxCoreError> {
    guard(|| {
        vox_core::prepare(preparation_json)
            .and_then(|value| vox_core::canonical_bytes(&value))
            .map_err(Into::into)
    })
}

#[derive(uniffi::Object)]
pub struct CoreMaterializationSession {
    inner: Mutex<MaterializationSession>,
}

#[uniffi::export]
impl CoreMaterializationSession {
    pub fn push_observation(
        &self,
        stream_id: &str,
        sequence: u32,
        bytes: &[u8],
        eof: bool,
    ) -> Result<(), VoxCoreError> {
        guard(|| {
            let stream_id = uuid_from_string(stream_id)?;
            self.inner
                .lock()
                .map_err(|_| VoxCoreError::InternalPanic)?
                .push_observation(stream_id, sequence, bytes, eof)
                .map_err(Into::into)
        })
    }

    pub fn seal(&self) -> Result<CoreArtifactDescriptors, VoxCoreError> {
        guard(|| {
            self.inner
                .lock()
                .map_err(|_| VoxCoreError::InternalPanic)?
                .seal()
                .map(|value| CoreArtifactDescriptors {
                    request_id: value.request_id.to_string(),
                    artifacts: value
                        .artifacts
                        .into_iter()
                        .map(|item| CoreArtifactDescriptor {
                            artifact_id: item.artifact_id.to_string(),
                            operation_id: item.operation_id.to_string(),
                            stream_id: item.stream_id.to_string(),
                            commit_sequence: item.commit_sequence,
                            kind: item.kind.to_owned(),
                            media_type: item.media_type.to_owned(),
                            length: item.length,
                            result_sha256: item.result_sha256,
                            receipt_kind: item.receipt_kind.to_owned(),
                        })
                        .collect(),
                })
                .map_err(Into::into)
        })
    }

    pub fn drain(
        &self,
        artifact_id: &str,
        sequence: u32,
        maximum_bytes: u64,
    ) -> Result<CorePreparedChunk, VoxCoreError> {
        guard(|| {
            let artifact_id = uuid_from_string(artifact_id)?;
            self.inner
                .lock()
                .map_err(|_| VoxCoreError::InternalPanic)?
                .drain(artifact_id, sequence, maximum_bytes)
                .map(|value| CorePreparedChunk {
                    artifact_id: value.artifact_id.to_string(),
                    stream_id: value.stream_id.to_string(),
                    sequence: value.sequence,
                    bytes: value.bytes,
                    byte_count: value.byte_count,
                    chunk_sha256: value.chunk_sha256,
                    eof: value.eof,
                })
                .map_err(Into::into)
        })
    }

    pub fn finalize(&self, drained_hashes_json: &[u8]) -> Result<Vec<u8>, VoxCoreError> {
        guard(|| {
            let hashes: DrainedHashes =
                vox_core::parse_control(drained_hashes_json).map_err(VoxCoreError::from)?;
            self.inner
                .lock()
                .map_err(|_| VoxCoreError::InternalPanic)?
                .finalize(&hashes)
                .map_err(Into::into)
        })
    }

    pub fn cancel(&self) {
        if let Ok(mut session) = self.inner.lock() {
            session.cancel();
        }
    }
}

#[uniffi::export]
pub fn core_start_materialization(
    control_json: &[u8],
) -> Result<Arc<CoreMaterializationSession>, VoxCoreError> {
    guard(|| {
        MaterializationSession::new(control_json)
            .map(|inner| {
                Arc::new(CoreMaterializationSession {
                    inner: Mutex::new(inner),
                })
            })
            .map_err(Into::into)
    })
}

fn uuid_from_string(value: &str) -> Result<uuid::Uuid, VoxCoreError> {
    uuid::Uuid::parse_str(value).map_err(|_| VoxCoreError::Correlation)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_is_contained() {
        let result: Result<(), VoxCoreError> = guard(|| panic!("private panic value"));
        assert_eq!(result, Err(VoxCoreError::InternalPanic));
    }

    #[test]
    fn errors_carry_no_dynamic_values() {
        assert_eq!(
            VoxCoreError::VerificationFailed.to_string(),
            "output verification failed"
        );
    }
}
