#![forbid(unsafe_code)]

//! Pure, deterministic M2 core. This crate performs no I/O and owns no platform handles.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{Datelike, TimeZone, Timelike};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub const CORE_API_VERSION: u32 = 1;
pub const PREPARATION_INPUT_VERSION: u32 = 1;
pub const REQUIRED_OBSERVATIONS_VERSION: u32 = 1;
pub const MATERIALIZATION_INPUT_VERSION: u32 = 1;
pub const ARTIFACT_PLAN_VERSION: u32 = 1;
pub const CORE_VERSION: &str = "0.1.0-alpha.1";
pub const RENDERER_REVISION: &str = "swift-legacy-m0";
pub const PROFILE_ID: &str = "apple-parity-v1";
pub const PROFILE_VERSION: u32 = 1;
pub const MAX_CONTROL_BYTES: usize = 1_048_576;
pub const MAX_CHUNK_BYTES: usize = 1_048_576;
pub const MAX_AGGREGATE_BYTES: u64 = 268_435_456;
pub const TOOLCHAIN_MANIFEST_SHA256: &str = env!("VOX_TOOLCHAIN_MANIFEST_SHA256");
pub const SOURCE_REVISION: &str = env!("VOX_CORE_SOURCE_REVISION");
const ZERO_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const UUID_NAMESPACE: Uuid = Uuid::from_bytes([
    0x8c, 0x7f, 0x8d, 0x7e, 0x4f, 0x61, 0x5d, 0x92, 0xa9, 0x4a, 0x3b, 0x9e, 0x6c, 0xc8, 0xe4, 0x15,
]);

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CoreError {
    #[error("control input exceeds the size limit")]
    ControlTooLarge,
    #[error("control input is invalid")]
    InvalidControl,
    #[error("control input contains an unknown field")]
    UnknownField,
    #[error("control input is not canonical")]
    NonCanonicalControl,
    #[error("core API version is unsupported")]
    UnsupportedCoreApi,
    #[error("preparation input version is unsupported")]
    UnsupportedPreparationInput,
    #[error("required observations version is unsupported")]
    UnsupportedRequiredObservations,
    #[error("materialization input version is unsupported")]
    UnsupportedMaterializationInput,
    #[error("artifact plan version is unsupported")]
    UnsupportedArtifactPlan,
    #[error("renderer is unsupported")]
    UnsupportedRenderer,
    #[error("profile is unsupported")]
    UnsupportedProfile,
    #[error("operation is unsupported")]
    UnsupportedOperation,
    #[error("model is unsupported")]
    UnsupportedModel,
    #[error("toolchain manifest does not match")]
    ToolchainManifestMismatch,
    #[error("request identity does not match")]
    RequestMismatch,
    #[error("snapshot does not match")]
    SnapshotMismatch,
    #[error("observation list does not match")]
    ObservationMismatch,
    #[error("observation stream is invalid")]
    InvalidObservationStream,
    #[error("observation sequence is invalid")]
    ObservationSequence,
    #[error("chunk exceeds the size limit")]
    ChunkTooLarge,
    #[error("aggregate input exceeds the size limit")]
    AggregateTooLarge,
    #[error("session input is incomplete")]
    Incomplete,
    #[error("output descriptor does not match")]
    DescriptorMismatch,
    #[error("drained artifact does not match")]
    DrainedHashMismatch,
    #[error("path plan is invalid")]
    InvalidPath,
    #[error("path collision policy is unsupported")]
    UnsupportedCollisionSemantics,
    #[error("rendering failed validation")]
    InvalidRendering,
    #[error("session is terminal")]
    SessionTerminal,
    #[error("session was cancelled")]
    Cancelled,
    #[error("serialization failed")]
    Serialization,
}

impl CoreError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::ControlTooLarge => "controlTooLarge",
            Self::InvalidControl => "invalidControl",
            Self::UnknownField => "unknownField",
            Self::NonCanonicalControl => "nonCanonicalControl",
            Self::UnsupportedCoreApi => "unsupportedCoreAPI",
            Self::UnsupportedPreparationInput => "unsupportedPreparationInput",
            Self::UnsupportedRequiredObservations => "unsupportedRequiredObservations",
            Self::UnsupportedMaterializationInput => "unsupportedMaterializationInput",
            Self::UnsupportedArtifactPlan => "unsupportedArtifactPlan",
            Self::UnsupportedRenderer => "unsupportedRenderer",
            Self::UnsupportedProfile => "unsupportedProfile",
            Self::UnsupportedOperation => "unsupportedOperation",
            Self::UnsupportedModel => "unsupportedModel",
            Self::ToolchainManifestMismatch => "toolchainManifestMismatch",
            Self::RequestMismatch => "requestMismatch",
            Self::SnapshotMismatch => "snapshotMismatch",
            Self::ObservationMismatch => "observationMismatch",
            Self::InvalidObservationStream => "invalidObservationStream",
            Self::ObservationSequence => "observationSequence",
            Self::ChunkTooLarge => "chunkTooLarge",
            Self::AggregateTooLarge => "aggregateTooLarge",
            Self::Incomplete => "incomplete",
            Self::DescriptorMismatch => "descriptorMismatch",
            Self::DrainedHashMismatch => "drainedHashMismatch",
            Self::InvalidPath => "invalidPath",
            Self::UnsupportedCollisionSemantics => "unsupportedCollisionSemantics",
            Self::InvalidRendering => "invalidRendering",
            Self::SessionTerminal => "sessionTerminal",
            Self::Cancelled => "cancelled",
            Self::Serialization => "serialization",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildInfo {
    pub kind: &'static str,
    #[serde(rename = "coreAPIVersion")]
    pub core_api_version: u32,
    pub core_version: &'static str,
    pub source_revision: &'static str,
    pub build_configuration: &'static str,
    pub toolchain_manifest_sha256: &'static str,
    pub supported_operations: [&'static str; 1],
    #[serde(rename = "supportedProfileIDs")]
    pub supported_profile_ids: [&'static str; 1],
}

pub const fn build_info() -> BuildInfo {
    BuildInfo {
        kind: "buildInfo",
        core_api_version: CORE_API_VERSION,
        core_version: CORE_VERSION,
        source_revision: SOURCE_REVISION,
        build_configuration: if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        },
        toolchain_manifest_sha256: TOOLCHAIN_MANIFEST_SHA256,
        supported_operations: ["newNoteTextLink"],
        supported_profile_ids: [PROFILE_ID],
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Versions {
    #[serde(rename = "coreAPIVersion")]
    pub core_api_version: u32,
    pub capture_preparation_input_version: u32,
    pub required_observations_version: u32,
    pub capture_materialization_input_version: u32,
    pub artifact_plan_version: u32,
    pub renderer_revision: String,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub profile_version: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadinessRequest {
    pub kind: String,
    pub operation: String,
    pub versions: Versions,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessResult {
    pub kind: &'static str,
    pub status: &'static str,
    pub session_permitted: bool,
    pub mismatch_codes: Vec<&'static str>,
}

pub fn readiness(bytes: &[u8]) -> Result<ReadinessResult, CoreError> {
    let request: ReadinessRequest = parse_control(bytes)?;
    if request.kind != "expectedVersions" {
        return Err(CoreError::InvalidControl);
    }
    let mut mismatches = Vec::new();
    if request.operation != "newNoteTextLink" {
        mismatches.push("unsupportedOperation");
    }
    let versions = request.versions;
    if versions.core_api_version != CORE_API_VERSION {
        mismatches.push("unsupportedCoreAPI");
    }
    if versions.capture_preparation_input_version != PREPARATION_INPUT_VERSION {
        mismatches.push("unsupportedPreparationInput");
    }
    if versions.required_observations_version != REQUIRED_OBSERVATIONS_VERSION {
        mismatches.push("unsupportedRequiredObservations");
    }
    if versions.capture_materialization_input_version != MATERIALIZATION_INPUT_VERSION {
        mismatches.push("unsupportedMaterializationInput");
    }
    if versions.artifact_plan_version != ARTIFACT_PLAN_VERSION {
        mismatches.push("unsupportedArtifactPlan");
    }
    if versions.renderer_revision != RENDERER_REVISION {
        mismatches.push("unsupportedRenderer");
    }
    if versions.profile_id != PROFILE_ID || versions.profile_version != PROFILE_VERSION {
        mismatches.push("unsupportedProfile");
    }
    let ready = mismatches.is_empty();
    Ok(ReadinessResult {
        kind: "readinessResult",
        status: if ready { "ready" } else { "incompatible" },
        session_permitted: ready,
        mismatch_codes: mismatches,
    })
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Pins {
    pub core_version: String,
    pub renderer_revision: String,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub profile_version: u32,
    #[serde(rename = "modelProfileID")]
    pub model_profile_id: Option<String>,
    pub model_revision: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all_fields = "camelCase", deny_unknown_fields)]
pub enum Payload {
    #[serde(rename = "text")]
    Text { id: Uuid, text: String },
    #[serde(rename = "link")]
    Link {
        id: Uuid,
        url: String,
        label: String,
    },
    #[serde(rename = "asset")]
    Asset {
        id: Uuid,
        source_id: Uuid,
        media_type: String,
        length: u64,
        sha256: String,
        safe_extension: String,
        original_name_policy: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RoutePolicy {
    pub logical_folder: Vec<String>,
    pub note_name_template: String,
    pub extension_policy: String,
    pub collision_policy: String,
    pub attachment_folder: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrderedField {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MetadataPolicy {
    pub frontmatter_mode: String,
    pub ordered_fields: Vec<OrderedField>,
    pub template_policy: String,
    pub line_ending: String,
    pub final_newline: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DestinationPolicy {
    pub capability_reference: String,
    pub capability_class: String,
    pub expected_case_sensitivity: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preset {
    pub id: Uuid,
    pub revision: u64,
    pub snapshot_hash: String,
    pub template_freeze_point: String,
    pub retry_marker_policy: String,
    pub route_policy: RoutePolicy,
    pub metadata_policy: MetadataPolicy,
    pub destination_policy: DestinationPolicy,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Invocation {
    pub sequence: u64,
    #[serde(rename = "originRecordingID")]
    pub origin_recording_id: Option<Uuid>,
    pub location_outcome: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreparationInput {
    pub contract_version: u32,
    #[serde(rename = "requestID")]
    pub request_id: Uuid,
    pub capture_source: String,
    pub created_at_epoch_milliseconds: i64,
    pub timezone: String,
    pub calendar: String,
    pub locale: String,
    pub operation: String,
    pub pins: Pins,
    pub payloads: Vec<Payload>,
    pub preset: Preset,
    pub invocation: Invocation,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionPolicy {
    pub maximum_chunk_bytes: u64,
    pub maximum_aggregate_observation_bytes: u64,
    pub input_ordering: String,
    pub single_seal: bool,
    pub single_finalize: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all_fields = "camelCase", deny_unknown_fields)]
pub enum ObservationResult {
    #[serde(rename = "candidateOccupancy")]
    CandidateOccupancy {
        #[serde(rename = "observationID")]
        observation_id: Uuid,
        status: String,
        logical_paths: Vec<Vec<String>>,
        ordered_set_hash: String,
    },
    #[serde(rename = "frozenTemplate")]
    FrozenTemplate {
        #[serde(rename = "observationID")]
        observation_id: Uuid,
        status: String,
        length: u64,
        sha256: String,
        #[serde(rename = "byteStreamID")]
        byte_stream_id: Option<Uuid>,
    },
    #[serde(rename = "existingNote")]
    ExistingNote {
        #[serde(rename = "observationID")]
        observation_id: Uuid,
        status: String,
        logical_path: Vec<String>,
        length: u64,
        sha256: String,
        #[serde(rename = "byteStreamID")]
        byte_stream_id: Uuid,
    },
    #[serde(rename = "stagedAssetMetadata")]
    StagedAssetMetadata {
        #[serde(rename = "observationID")]
        observation_id: Uuid,
        status: String,
        assets: Vec<StagedAsset>,
        ordered_set_hash: String,
    },
}

impl ObservationResult {
    const fn id(&self) -> Uuid {
        match self {
            Self::CandidateOccupancy { observation_id, .. }
            | Self::FrozenTemplate { observation_id, .. }
            | Self::ExistingNote { observation_id, .. }
            | Self::StagedAssetMetadata { observation_id, .. } => *observation_id,
        }
    }

    const fn stream(&self) -> Option<(Uuid, u64)> {
        match self {
            Self::FrozenTemplate {
                byte_stream_id: Some(id),
                length,
                ..
            }
            | Self::ExistingNote {
                byte_stream_id: id,
                length,
                ..
            } => Some((*id, *length)),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StagedAsset {
    #[serde(rename = "sourceID")]
    pub source_id: Uuid,
    pub media_type: String,
    pub length: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MaterializationInput {
    pub contract_version: u32,
    #[serde(rename = "requestID")]
    pub request_id: Uuid,
    pub capture_source: String,
    pub created_at_epoch_milliseconds: i64,
    pub timezone: String,
    pub calendar: String,
    pub locale: String,
    pub operation: String,
    pub pins: Pins,
    pub payloads: Vec<Payload>,
    pub preset: Preset,
    pub preparation_revision: u64,
    pub snapshot_hash: String,
    pub control_byte_count: u64,
    pub observations: Vec<ObservationResult>,
    pub session: SessionPolicy,
    pub invocation: Invocation,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservationRequest {
    pub kind: &'static str,
    pub id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logical_candidates: Option<Vec<Vec<String>>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub maximum_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template_capability_reference: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequiredObservations {
    pub contract_version: u32,
    #[serde(rename = "requestID")]
    pub request_id: Uuid,
    pub preparation_revision: u64,
    pub snapshot_hash: String,
    pub observations: Vec<ObservationRequest>,
    pub aggregate_maximum_bytes: u64,
    pub ordering: &'static str,
}

pub fn prepare(bytes: &[u8]) -> Result<RequiredObservations, CoreError> {
    let input: PreparationInput = parse_control(bytes)?;
    validate_preparation(&input)?;
    let candidates = path_candidates(&input)?;
    let mut observations = vec![ObservationRequest {
        kind: "candidateOccupancy",
        id: derived_uuid(
            "vox.observation.v1",
            &json!({"kind":"candidateOccupancy","requestID":input.request_id}),
        )?,
        logical_candidates: Some(candidates),
        required: None,
        maximum_bytes: None,
        template_capability_reference: None,
    }];
    if input.preset.metadata_policy.template_policy == "frozenObservation" {
        observations.push(ObservationRequest {
            kind: "frozenTemplate",
            id: derived_uuid(
                "vox.observation.v1",
                &json!({"kind":"frozenTemplate","requestID":input.request_id}),
            )?,
            logical_candidates: None,
            required: Some(false),
            maximum_bytes: Some(MAX_AGGREGATE_BYTES),
            template_capability_reference: Some("native-frozen-template-v1".to_owned()),
        });
    }
    let snapshot_hash = sha256_hex(&canonical_bytes(&input)?);
    Ok(RequiredObservations {
        contract_version: REQUIRED_OBSERVATIONS_VERSION,
        request_id: input.request_id,
        preparation_revision: 1,
        snapshot_hash,
        observations,
        aggregate_maximum_bytes: MAX_AGGREGATE_BYTES,
        ordering: "listed",
    })
}

fn validate_preparation(input: &PreparationInput) -> Result<(), CoreError> {
    if input.contract_version != PREPARATION_INPUT_VERSION {
        return Err(CoreError::UnsupportedPreparationInput);
    }
    if input.operation != "newNote" {
        return Err(CoreError::UnsupportedOperation);
    }
    validate_pins(&input.pins)?;
    if input.payloads.is_empty() || input.payloads.len() > 128 {
        return Err(CoreError::InvalidControl);
    }
    if input
        .payloads
        .iter()
        .any(|item| matches!(item, Payload::Asset { .. }))
    {
        return Err(CoreError::UnsupportedOperation);
    }
    if input.calendar != "gregorian" || input.locale.is_empty() || input.locale.len() > 35 {
        return Err(CoreError::InvalidControl);
    }
    if input.preset.destination_policy.capability_class != "userVault" {
        return Err(CoreError::UnsupportedOperation);
    }
    if input.preset.destination_policy.expected_case_sensitivity != "sensitive" {
        return Err(CoreError::UnsupportedCollisionSemantics);
    }
    if input.preset.route_policy.collision_policy != "deterministicSuffix" {
        return Err(CoreError::UnsupportedCollisionSemantics);
    }
    if input.preset.route_policy.extension_policy != "markdownDotMd"
        || input.preset.template_freeze_point != "firstPreparation"
        || input.preset.metadata_policy.line_ending != "lf"
        || !matches!(
            input.preset.metadata_policy.frontmatter_mode.as_str(),
            "none" | "merge"
        )
        || !matches!(
            input.preset.metadata_policy.template_policy.as_str(),
            "none" | "frozenObservation"
        )
        || !matches!(
            input.preset.retry_marker_policy.as_str(),
            "none" | "voxCaptureCommentV1"
        )
    {
        return Err(CoreError::InvalidControl);
    }
    validate_segments(&input.preset.route_policy.logical_folder)?;
    Ok(())
}

fn validate_pins(pins: &Pins) -> Result<(), CoreError> {
    if pins.core_version != CORE_VERSION {
        return Err(CoreError::UnsupportedCoreApi);
    }
    if pins.renderer_revision != RENDERER_REVISION {
        return Err(CoreError::UnsupportedRenderer);
    }
    if pins.profile_id != PROFILE_ID || pins.profile_version != PROFILE_VERSION {
        return Err(CoreError::UnsupportedProfile);
    }
    if pins.model_profile_id.is_some() || pins.model_revision.is_some() {
        return Err(CoreError::UnsupportedModel);
    }
    Ok(())
}

pub fn path_candidates(input: &PreparationInput) -> Result<Vec<Vec<String>>, CoreError> {
    let rendered = render_tokens(
        &input.preset.route_policy.note_name_template,
        input.created_at_epoch_milliseconds,
        &input.timezone,
        input.request_id,
        &input.capture_source,
    )?;
    let trimmed = rendered.trim_matches(char::is_whitespace);
    let name = if suffix_extension(trimmed).is_some() {
        trimmed.to_owned()
    } else {
        format!("{trimmed}.md")
    };
    validate_segment(&name)?;
    let mut result = Vec::with_capacity(256);
    for suffix in 1..=256_u16 {
        let mut path = input.preset.route_policy.logical_folder.clone();
        let candidate = if suffix == 1 {
            name.clone()
        } else {
            suffixed(&name, suffix)
        };
        path.push(candidate);
        result.push(path);
    }
    Ok(result)
}

fn suffixed(name: &str, suffix: u16) -> String {
    match suffix_extension(name) {
        Some((stem, extension)) => format!("{stem}-{suffix}.{extension}"),
        None => format!("{name}-{suffix}"),
    }
}

fn suffix_extension(name: &str) -> Option<(&str, &str)> {
    let index = name.rfind('.')?;
    (index > 0 && index + 1 < name.len()).then(|| (&name[..index], &name[index + 1..]))
}

pub fn render_tokens(
    template: &str,
    epoch_ms: i64,
    timezone: &str,
    request_id: Uuid,
    source: &str,
) -> Result<String, CoreError> {
    let timezone: Tz = timezone.parse().map_err(|_| CoreError::InvalidControl)?;
    let date = timezone
        .timestamp_millis_opt(epoch_ms)
        .single()
        .ok_or(CoreError::InvalidControl)?;
    let iso = date.iso_week();
    let year = format!("{:04}", date.year());
    let month = format!("{:02}", date.month());
    let day = format!("{:02}", date.day());
    let hour = format!("{:02}", date.hour());
    let minute = format!("{:02}", date.minute());
    let second = format!("{:02}", date.second());
    let week = format!("{:04}-W{:02}", iso.year(), iso.week());
    let id = request_id.hyphenated().to_string();
    let replacements = [
        (
            "{timestamp}",
            format!("{year}-{month}-{day}-{hour}{minute}{second}"),
        ),
        ("{date}", format!("{year}-{month}-{day}")),
        ("{time}", format!("{hour}{minute}{second}")),
        ("{year}", year.clone()),
        ("{YR}", year[year.len() - 2..].to_owned()),
        ("{month}", month),
        ("{day}", day),
        ("{week}", week),
        ("{hour}", hour),
        ("{minute}", minute),
        ("{second}", second),
        ("{source}", source.to_owned()),
        ("{id}", id.clone()),
        ("{id8}", id[..8].to_owned()),
    ];
    Ok(replacements
        .into_iter()
        .fold(template.to_owned(), |value, (token, replacement)| {
            value.replace(token, &replacement)
        }))
}

fn validate_segments(segments: &[String]) -> Result<(), CoreError> {
    if segments.len() > 32 {
        return Err(CoreError::InvalidPath);
    }
    segments
        .iter()
        .try_for_each(|segment| validate_segment(segment))
}

fn validate_segment(segment: &str) -> Result<(), CoreError> {
    if segment.is_empty()
        || segment.len() > 255
        || matches!(segment, "." | "..")
        || segment.contains(['/', '\\', '\0'])
    {
        return Err(CoreError::InvalidPath);
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactDescriptor {
    #[serde(rename = "artifactID")]
    pub artifact_id: Uuid,
    #[serde(rename = "operationID")]
    pub operation_id: Uuid,
    #[serde(rename = "streamID")]
    pub stream_id: Uuid,
    pub commit_sequence: u32,
    pub kind: &'static str,
    pub media_type: &'static str,
    pub length: u64,
    #[serde(rename = "resultSHA256")]
    pub result_sha256: String,
    pub receipt_kind: &'static str,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactDescriptors {
    pub kind: &'static str,
    #[serde(rename = "requestID")]
    pub request_id: Uuid,
    pub artifacts: Vec<ArtifactDescriptor>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedChunk {
    pub kind: &'static str,
    #[serde(rename = "artifactID")]
    pub artifact_id: Uuid,
    #[serde(rename = "streamID")]
    pub stream_id: Uuid,
    pub sequence: u32,
    pub bytes: Vec<u8>,
    pub byte_count: u64,
    pub chunk_sha256: String,
    pub eof: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DrainedHashes {
    pub kind: String,
    #[serde(rename = "requestID")]
    pub request_id: Uuid,
    pub artifacts: Vec<DrainedArtifactHash>,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DrainedArtifactHash {
    #[serde(rename = "artifactID")]
    pub artifact_id: Uuid,
    #[serde(rename = "streamID")]
    pub stream_id: Uuid,
    pub length: u64,
    #[serde(rename = "resultSHA256")]
    pub result_sha256: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State {
    Input,
    Sealed,
    Draining,
    Drained,
    Finalized,
    Cancelled,
    Failed,
}

#[derive(Clone, Debug)]
struct InputStream {
    id: Uuid,
    expected_length: u64,
    expected_sha256: String,
    length: u64,
    hasher: Sha256,
    template: Option<Vec<u8>>,
    next_sequence: u32,
    eof: bool,
}

#[derive(Clone, Debug)]
pub struct MaterializationSession {
    input: MaterializationInput,
    state: State,
    streams: Vec<InputStream>,
    next_stream: usize,
    aggregate: u64,
    output: Option<Vec<u8>>,
    descriptor: Option<ArtifactDescriptor>,
    drain_offset: usize,
    drain_sequence: u32,
}

impl MaterializationSession {
    pub fn new(control: &[u8]) -> Result<Self, CoreError> {
        let input: MaterializationInput = parse_control(control)?;
        validate_materialization(&input, control.len())?;
        let mut seen = BTreeSet::new();
        let mut streams = Vec::new();
        for observation in &input.observations {
            if !seen.insert(observation.id()) {
                return Err(CoreError::ObservationMismatch);
            }
            match observation {
                ObservationResult::CandidateOccupancy {
                    status,
                    logical_paths,
                    ordered_set_hash,
                    ..
                } => {
                    if status != "present"
                        || sha256_hex(&canonical_bytes(logical_paths)?) != *ordered_set_hash
                    {
                        return Err(CoreError::ObservationMismatch);
                    }
                }
                ObservationResult::FrozenTemplate {
                    status,
                    length,
                    sha256,
                    byte_stream_id,
                    ..
                } => {
                    let absent = status == "absent"
                        && *length == 0
                        && sha256 == ZERO_HASH
                        && byte_stream_id.is_none();
                    let present = status == "present" && byte_stream_id.is_some();
                    if !absent && !present {
                        return Err(CoreError::ObservationMismatch);
                    }
                }
                ObservationResult::ExistingNote { .. }
                | ObservationResult::StagedAssetMetadata { .. } => {
                    return Err(CoreError::UnsupportedOperation);
                }
            }
            if let Some((id, length)) = observation.stream() {
                let sha256 = match observation {
                    ObservationResult::FrozenTemplate { sha256, .. }
                    | ObservationResult::ExistingNote { sha256, .. } => sha256.clone(),
                    _ => unreachable!(),
                };
                streams.push(InputStream {
                    id,
                    expected_length: length,
                    expected_sha256: sha256,
                    length: 0,
                    hasher: Sha256::new(),
                    template: matches!(observation, ObservationResult::FrozenTemplate { .. })
                        .then(Vec::new),
                    next_sequence: 0,
                    eof: false,
                });
            }
        }
        Ok(Self {
            input,
            state: State::Input,
            streams,
            next_stream: 0,
            aggregate: 0,
            output: None,
            descriptor: None,
            drain_offset: 0,
            drain_sequence: 0,
        })
    }

    pub fn push_observation(
        &mut self,
        stream_id: Uuid,
        sequence: u32,
        bytes: &[u8],
        eof: bool,
    ) -> Result<(), CoreError> {
        self.ensure_state(State::Input)?;
        if bytes.len() > MAX_CHUNK_BYTES {
            return self.fail(CoreError::ChunkTooLarge);
        }
        let Some(stream) = self.streams.get_mut(self.next_stream) else {
            return self.fail(CoreError::ObservationSequence);
        };
        if stream.id != stream_id || stream.next_sequence != sequence || stream.eof {
            return self.fail(CoreError::ObservationSequence);
        }
        self.aggregate = self
            .aggregate
            .checked_add(bytes.len() as u64)
            .ok_or(CoreError::AggregateTooLarge)?;
        if self.aggregate > MAX_AGGREGATE_BYTES {
            return self.fail(CoreError::AggregateTooLarge);
        }
        stream.length += bytes.len() as u64;
        if stream.length > stream.expected_length {
            return self.fail(CoreError::InvalidObservationStream);
        }
        stream.hasher.update(bytes);
        if let Some(template) = &mut stream.template {
            template.extend_from_slice(bytes);
        }
        stream.next_sequence += 1;
        if eof {
            stream.eof = true;
            if stream.length != stream.expected_length
                || format!("{:x}", stream.hasher.clone().finalize()) != stream.expected_sha256
            {
                return self.fail(CoreError::InvalidObservationStream);
            }
            self.next_stream += 1;
        }
        Ok(())
    }

    pub fn seal(&mut self) -> Result<ArtifactDescriptors, CoreError> {
        self.ensure_state(State::Input)?;
        if self.next_stream != self.streams.len() {
            return self.fail(CoreError::Incomplete);
        }
        let template = self
            .streams
            .iter()
            .find_map(|stream| stream.template.as_deref());
        let (path, bytes) = materialize(&self.input, template)?;
        let hash = sha256_hex(&bytes);
        let operation_id = operation_id(self.input.request_id, 0, "newNote")?;
        let artifact_id = artifact_id(operation_id, "note", &path)?;
        let stream_id = stream_id(artifact_id, bytes.len() as u64, &hash)?;
        let descriptor = ArtifactDescriptor {
            artifact_id,
            operation_id,
            stream_id,
            commit_sequence: 0,
            kind: "note",
            media_type: "text/markdown; charset=utf-8",
            length: bytes.len() as u64,
            result_sha256: hash,
            receipt_kind: "noteCommit",
        };
        self.output = Some(bytes);
        self.descriptor = Some(descriptor.clone());
        self.state = State::Sealed;
        Ok(ArtifactDescriptors {
            kind: "expectedArtifactDescriptors",
            request_id: self.input.request_id,
            artifacts: vec![descriptor],
        })
    }

    pub fn drain(&mut self, artifact_id: Uuid, sequence: u32) -> Result<PreparedChunk, CoreError> {
        if !matches!(self.state, State::Sealed | State::Draining) {
            return self.terminal_error();
        }
        let descriptor = self.descriptor.as_ref().ok_or(CoreError::Incomplete)?;
        if descriptor.artifact_id != artifact_id || sequence != self.drain_sequence {
            return self.fail(CoreError::DescriptorMismatch);
        }
        let output = self.output.as_ref().ok_or(CoreError::Incomplete)?;
        let end = output.len().min(self.drain_offset + MAX_CHUNK_BYTES);
        let bytes = output[self.drain_offset..end].to_vec();
        let eof = end == output.len();
        let chunk = PreparedChunk {
            kind: "preparedChunkMetadata",
            artifact_id,
            stream_id: descriptor.stream_id,
            sequence,
            byte_count: bytes.len() as u64,
            chunk_sha256: sha256_hex(&bytes),
            bytes,
            eof,
        };
        self.drain_offset = end;
        self.drain_sequence += 1;
        self.state = if eof { State::Drained } else { State::Draining };
        Ok(chunk)
    }

    pub fn finalize(&mut self, drained: &DrainedHashes) -> Result<Vec<u8>, CoreError> {
        if self.state != State::Drained {
            return self.terminal_error();
        }
        let descriptor = self.descriptor.as_ref().ok_or(CoreError::Incomplete)?;
        let coherent = drained.kind == "drainedArtifactHashes"
            && drained.request_id == self.input.request_id
            && drained.artifacts.as_slice()
                == [DrainedArtifactHash {
                    artifact_id: descriptor.artifact_id,
                    stream_id: descriptor.stream_id,
                    length: descriptor.length,
                    result_sha256: descriptor.result_sha256.clone(),
                }];
        if !coherent {
            return self.fail(CoreError::DrainedHashMismatch);
        }
        let path = selected_path(&self.input)?;
        let plan = plan_value(&self.input, descriptor, &path)?;
        self.state = State::Finalized;
        canonical_bytes(&plan)
    }

    pub fn cancel(&mut self) {
        if !matches!(self.state, State::Finalized | State::Failed) {
            self.state = State::Cancelled;
            self.output = None;
        }
    }

    pub const fn aggregate_bytes(&self) -> u64 {
        self.aggregate
    }

    fn ensure_state(&self, expected: State) -> Result<(), CoreError> {
        if self.state == expected {
            Ok(())
        } else {
            self.terminal_error()
        }
    }

    fn terminal_error<T>(&self) -> Result<T, CoreError> {
        Err(if self.state == State::Cancelled {
            CoreError::Cancelled
        } else {
            CoreError::SessionTerminal
        })
    }

    fn fail<T>(&mut self, error: CoreError) -> Result<T, CoreError> {
        self.state = State::Failed;
        self.output = None;
        Err(error)
    }
}

fn validate_materialization(
    input: &MaterializationInput,
    byte_count: usize,
) -> Result<(), CoreError> {
    if byte_count > MAX_CONTROL_BYTES
        || input.control_byte_count == 0
        || input.control_byte_count > MAX_CONTROL_BYTES as u64
    {
        return Err(CoreError::ControlTooLarge);
    }
    if input.contract_version != MATERIALIZATION_INPUT_VERSION {
        return Err(CoreError::UnsupportedMaterializationInput);
    }
    let preparation = PreparationInput {
        contract_version: PREPARATION_INPUT_VERSION,
        request_id: input.request_id,
        capture_source: input.capture_source.clone(),
        created_at_epoch_milliseconds: input.created_at_epoch_milliseconds,
        timezone: input.timezone.clone(),
        calendar: input.calendar.clone(),
        locale: input.locale.clone(),
        operation: input.operation.clone(),
        pins: input.pins.clone(),
        payloads: input.payloads.clone(),
        preset: input.preset.clone(),
        invocation: input.invocation.clone(),
    };
    validate_preparation(&preparation)?;
    let required = prepare(&canonical_bytes(&preparation)?)?;
    if input.preparation_revision != required.preparation_revision
        || input.snapshot_hash != required.snapshot_hash
        || input.observations.len() != required.observations.len()
        || input
            .observations
            .iter()
            .zip(&required.observations)
            .any(|(actual, expected)| {
                actual.id() != expected.id
                    || !matches!(
                        (actual, expected.kind),
                        (
                            ObservationResult::CandidateOccupancy { .. },
                            "candidateOccupancy"
                        ) | (ObservationResult::FrozenTemplate { .. }, "frozenTemplate")
                    )
            })
        || input.session.maximum_chunk_bytes != MAX_CHUNK_BYTES as u64
        || input.session.maximum_aggregate_observation_bytes != MAX_AGGREGATE_BYTES
        || input.session.input_ordering != "observation-list-then-sequence"
        || !input.session.single_seal
        || !input.session.single_finalize
    {
        return Err(CoreError::InvalidControl);
    }
    Ok(())
}

fn selected_path(input: &MaterializationInput) -> Result<Vec<String>, CoreError> {
    let prep = PreparationInput {
        contract_version: 1,
        request_id: input.request_id,
        capture_source: input.capture_source.clone(),
        created_at_epoch_milliseconds: input.created_at_epoch_milliseconds,
        timezone: input.timezone.clone(),
        calendar: input.calendar.clone(),
        locale: input.locale.clone(),
        operation: input.operation.clone(),
        pins: input.pins.clone(),
        payloads: input.payloads.clone(),
        preset: input.preset.clone(),
        invocation: input.invocation.clone(),
    };
    let candidates = path_candidates(&prep)?;
    let occupied = input
        .observations
        .iter()
        .find_map(|item| match item {
            ObservationResult::CandidateOccupancy { logical_paths, .. } => Some(logical_paths),
            _ => None,
        })
        .ok_or(CoreError::ObservationMismatch)?;
    let occupied: BTreeSet<_> = occupied.iter().cloned().collect();
    candidates
        .into_iter()
        .find(|candidate| !occupied.contains(candidate))
        .ok_or(CoreError::InvalidPath)
}

pub fn materialize(
    input: &MaterializationInput,
    template: Option<&[u8]>,
) -> Result<(Vec<String>, Vec<u8>), CoreError> {
    let path = selected_path(input)?;
    let mut blocks = Vec::new();
    for payload in &input.payloads {
        match payload {
            Payload::Text { text, .. } => {
                let text = text.trim_matches(['\r', '\n']);
                if !text.trim().is_empty() {
                    blocks.push(text.to_owned());
                }
            }
            Payload::Link { url, label, .. } => {
                let scheme = url
                    .split_once(':')
                    .map(|(scheme, _)| scheme.to_ascii_lowercase());
                if !matches!(scheme.as_deref(), Some("http" | "https")) {
                    return Err(CoreError::InvalidRendering);
                }
                let url = swift_url_absolute_string(url)?;
                let label = if label.trim().is_empty() {
                    url.as_str()
                } else {
                    label.trim()
                };
                blocks.push(format!("[{}]({})", escape_label(label), escape_url(&url)));
            }
            Payload::Asset { .. } => return Err(CoreError::UnsupportedOperation),
        }
    }
    if blocks.is_empty() {
        return Err(CoreError::InvalidRendering);
    }
    let mut entry = blocks.join("\n\n");
    if let Some(template) = template {
        let template = std::str::from_utf8(template).map_err(|_| CoreError::InvalidRendering)?;
        let rendered = render_tokens(
            template,
            input.created_at_epoch_milliseconds,
            &input.timezone,
            input.request_id,
            &input.capture_source,
        )?;
        let rendered = rendered.trim_matches(['\r', '\n']);
        if !rendered.is_empty() {
            entry = format!("{rendered}\n\n{entry}");
        }
    }
    if input.preset.metadata_policy.frontmatter_mode == "merge"
        && !input.preset.metadata_policy.ordered_fields.is_empty()
    {
        let mut fields = BTreeMap::new();
        for field in &input.preset.metadata_policy.ordered_fields {
            if field.name.is_empty()
                || field.name.contains(['\n', '\r'])
                || fields
                    .insert(field.name.as_str(), field.value.as_str())
                    .is_some()
            {
                return Err(CoreError::InvalidRendering);
            }
        }
        let lines = fields
            .into_iter()
            .map(|(name, value)| format!("{}: {}", yaml_key(name), yaml_scalar(value)))
            .collect::<Vec<_>>();
        entry = format!("---\n{}\n---\n\n{entry}", lines.join("\n"));
    }
    if input.preset.retry_marker_policy == "voxCaptureCommentV1" {
        entry.push_str("\n\n<!-- vox-capture:");
        entry.push_str(&input.request_id.hyphenated().to_string());
        entry.push_str(" -->");
    } else if input.preset.retry_marker_policy != "none" {
        return Err(CoreError::InvalidRendering);
    }
    if input.preset.metadata_policy.final_newline {
        entry.push('\n');
    }
    Ok((path, entry.into_bytes()))
}

fn escape_label(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]")
        .replace('\n', " ")
}

fn escape_url(value: &str) -> String {
    value.replace('(', "%28").replace(')', "%29")
}

fn swift_url_absolute_string(value: &str) -> Result<String, CoreError> {
    let mut output = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        if byte.is_ascii() {
            if byte.is_ascii_control() || *byte == b' ' {
                return Err(CoreError::InvalidRendering);
            }
            output.push(char::from(*byte));
        } else {
            use std::fmt::Write as _;
            write!(output, "%{byte:02X}").map_err(|_| CoreError::Serialization)?;
        }
    }
    Ok(output)
}

fn yaml_key(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '-'))
    {
        value.to_owned()
    } else {
        yaml_scalar(value)
    }
}

fn yaml_scalar(value: &str) -> String {
    let trimmed = value.trim();
    if (trimmed.starts_with('[') && trimmed.ends_with(']'))
        || (trimmed.starts_with('{') && trimmed.ends_with('}'))
        || matches!(
            trimmed.to_ascii_lowercase().as_str(),
            "true" | "false" | "null" | "~"
        )
        || trimmed.parse::<f64>().is_ok()
    {
        trimmed.to_owned()
    } else {
        format!(
            "\"{}\"",
            value
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n")
                .replace('\r', "\\r")
        )
    }
}

fn plan_value(
    input: &MaterializationInput,
    descriptor: &ArtifactDescriptor,
    path: &[String],
) -> Result<Value, CoreError> {
    let marker = if input.preset.retry_marker_policy == "voxCaptureCommentV1" {
        json!({"placement":"entrySuffixBeforeFinalNewline","policy":"voxCaptureCommentV1","syntax":"<!-- vox-capture:{lowercase-uuid} -->"})
    } else {
        json!({"placement":"none","policy":"none","syntax":""})
    };
    let mut value = json!({
        "artifacts": [{
            "artifactID": descriptor.artifact_id,
            "commitSequence": 0,
            "equivalenceRule": "exactBytes",
            "expectedExistingPolicy": "absent",
            "expectedExistingSHA256": Value::Null,
            "expectedOriginalSHA256": Value::Null,
            "journalFrontier": "noteVerified",
            "kind": "note",
            "logicalPath": path,
            "mediaType": descriptor.media_type,
            "operationID": descriptor.operation_id,
            "preparedStreamID": descriptor.stream_id,
            "receiptKind": "noteCommit",
            "resultLength": descriptor.length,
            "resultSHA256": descriptor.result_sha256,
            "writeMode": "create"
        }],
        "contractVersion": ARTIFACT_PLAN_VERSION,
        "diagnostics": [{"code":"materialized","fieldPath":"$","severity":"info"}],
        "operation": "newNote",
        "pins": input.pins,
        "planHash": ZERO_HASH,
        "preparedByteDelivery": {"finalJSONDuplicatesBytes":false,"maximumChunkBytes":MAX_CHUNK_BYTES,"mode":"drainedImmutableArtifacts"},
        "requestID": input.request_id,
        "retryMarker": marker,
        "warnings": []
    });
    let hash = sha256_hex(&canonical_bytes(&value)?);
    value["planHash"] = Value::String(hash);
    Ok(value)
}

pub fn operation_id(
    request_id: Uuid,
    commit_sequence: u32,
    operation: &str,
) -> Result<Uuid, CoreError> {
    derived_uuid(
        "vox.operation.v1",
        &json!({"commitSequence":commit_sequence,"operation":operation,"requestID":request_id}),
    )
}

pub fn artifact_id(
    operation_id: Uuid,
    kind: &str,
    logical_path: &[String],
) -> Result<Uuid, CoreError> {
    derived_uuid(
        "vox.artifact.v1",
        &json!({"kind":kind,"logicalPath":logical_path,"operationID":operation_id}),
    )
}

pub fn stream_id(
    artifact_id: Uuid,
    result_length: u64,
    result_sha256: &str,
) -> Result<Uuid, CoreError> {
    derived_uuid(
        "vox.stream.v1",
        &json!({"artifactID":artifact_id,"resultLength":result_length,"resultSHA256":result_sha256}),
    )
}

fn derived_uuid(domain: &str, preimage: &Value) -> Result<Uuid, CoreError> {
    let mut name = Vec::with_capacity(domain.len() + 1 + 256);
    name.extend_from_slice(domain.as_bytes());
    name.push(0);
    name.extend_from_slice(&canonical_bytes(preimage)?);
    // Contract UUIDv5 hashes namespace bytes plus the entire domain/NUL/preimage name.
    Ok(Uuid::new_v5(&UUID_NAMESPACE, &name))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub fn canonical_bytes<T: Serialize>(value: &T) -> Result<Vec<u8>, CoreError> {
    let value = serde_json::to_value(value).map_err(|_| CoreError::Serialization)?;
    let value = sorted_value(value);
    let mut bytes = serde_json::to_vec_pretty(&value).map_err(|_| CoreError::Serialization)?;
    bytes.push(b'\n');
    Ok(bytes)
}

fn sorted_value(value: Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut sorted = BTreeMap::new();
            for (key, value) in object {
                sorted.insert(key, sorted_value(value));
            }
            Value::Object(sorted.into_iter().collect::<Map<String, Value>>())
        }
        Value::Array(values) => Value::Array(values.into_iter().map(sorted_value).collect()),
        other => other,
    }
}

pub fn parse_control<T: for<'de> Deserialize<'de> + Serialize>(
    bytes: &[u8],
) -> Result<T, CoreError> {
    if bytes.len() > MAX_CONTROL_BYTES {
        return Err(CoreError::ControlTooLarge);
    }
    let parsed: T = serde_json::from_slice(bytes).map_err(|error| classify_json_error(&error))?;
    if canonical_bytes(&parsed)? != bytes {
        return Err(CoreError::NonCanonicalControl);
    }
    Ok(parsed)
}

fn classify_json_error(error: &serde_json::Error) -> CoreError {
    let message = error.to_string();
    if message.contains("unknown field") {
        CoreError::UnknownField
    } else {
        CoreError::InvalidControl
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_namespace_uses_sha1_v5() {
        let id = operation_id(
            Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap(),
            0,
            "newNote",
        )
        .unwrap();
        assert_eq!(id.get_version_num(), 5);
    }

    #[test]
    fn errors_are_privacy_safe() {
        let forbidden = ["/Users/", "content://", "file://", "11111111", "abcdef"];
        for error in [
            CoreError::InvalidControl,
            CoreError::InvalidPath,
            CoreError::DrainedHashMismatch,
        ] {
            assert!(
                forbidden
                    .iter()
                    .all(|value| !error.to_string().contains(value))
            );
        }
    }

    #[test]
    fn token_rendering_does_not_normalize_unicode() {
        let value = "Cafe\u{301}-{date}";
        let rendered = render_tokens(
            value,
            1_700_000_000_000,
            "America/Los_Angeles",
            Uuid::nil(),
            "app",
        )
        .unwrap();
        assert!(rendered.starts_with("Cafe\u{301}-"));
    }

    #[test]
    fn chunk_bounds_are_exact() {
        assert_eq!(MAX_CHUNK_BYTES, 1 << 20);
        assert_eq!(MAX_AGGREGATE_BYTES, 256 << 20);
    }
}
