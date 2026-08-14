use std::{fs, path::PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;
use vox_core::{
    ARTIFACT_PLAN_VERSION, CORE_API_VERSION, CORE_VERSION, CoreError, DrainedArtifactHash,
    DrainedHashes, MATERIALIZATION_INPUT_VERSION, MAX_AGGREGATE_BYTES, MAX_CHUNK_BYTES,
    MAX_PREPARED_CHUNK_SEQUENCE, MaterializationSession, PREPARATION_INPUT_VERSION, PROFILE_ID,
    PROFILE_VERSION, RENDERER_REVISION, REQUIRED_OBSERVATIONS_VERSION, TOOLCHAIN_MANIFEST_SHA256,
    canonical_bytes, operation_id, parse_control, prepare, readiness, sha256_hex,
};

fn canonical(value: &Value) -> Vec<u8> {
    canonical_bytes(value).unwrap()
}
fn uuid(value: &str) -> Uuid {
    Uuid::parse_str(value).unwrap()
}

fn prep_value() -> Value {
    json!({
      "calendar":"gregorian","captureSource":"app","contractVersion":1,
      "createdAtEpochMilliseconds":1_700_000_000_000_i64,
      "invocation":{"locationOutcome":"notRequested","originRecordingID":Value::Null,"sequence":1},
      "locale":"en-US","operation":"newNote",
      "payloads":[{"id":"22222222-2222-4222-8222-222222222222","kind":"text","text":"First"},{"id":"44444444-4444-4444-8444-444444444444","kind":"link","label":"A [label] \\ value","url":"https://example.invalid/a(b)"}],
      "pins":{"coreVersion":CORE_VERSION,"modelProfileID":Value::Null,"modelRevision":Value::Null,"profileID":PROFILE_ID,"profileVersion":PROFILE_VERSION,"rendererRevision":RENDERER_REVISION},
      "preset":{"destinationPolicy":{"capabilityClass":"userVault","capabilityReference":"synthetic","expectedCaseSensitivity":"sensitive"},"id":"33333333-3333-4333-8333-333333333333","metadataPolicy":{"finalNewline":true,"frontmatterMode":"merge","lineEnding":"lf","orderedFields":[{"name":"source","value":"synthetic"}],"templatePolicy":"none"},"retryMarkerPolicy":"voxCaptureCommentV1","revision":1,"routePolicy":{"attachmentFolder":[],"collisionPolicy":"deterministicSuffix","extensionPolicy":"markdownDotMd","logicalFolder":["Inbox"],"noteNameTemplate":"{date}-{id8}"},"snapshotHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","templateFreezePoint":"firstPreparation"},
      "requestID":"11111111-1111-4111-8111-111111111111","timezone":"America/Los_Angeles"
    })
}

fn mat_value(template: Option<&[u8]>) -> Value {
    let mut prep = prep_value();
    prep["preset"]["metadataPolicy"]["templatePolicy"] = json!(if template.is_some() {
        "frozenObservation"
    } else {
        "none"
    });
    let required = prepare(&canonical(&prep)).unwrap();
    let paths: Vec<Vec<String>> = vec![];
    let path_hash = sha256_hex(&canonical_bytes(&paths).unwrap());
    let candidate_id = required.observations[0].id;
    let mut observations = vec![
        json!({"kind":"candidateOccupancy","logicalPaths":paths,"observationID":candidate_id,"orderedSetHash":path_hash,"status":"present"}),
    ];
    if let Some(bytes) = template {
        observations.push(json!({"byteStreamID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","kind":"frozenTemplate","length":bytes.len(),"observationID":required.observations[1].id,"sha256":sha256_hex(bytes),"status":"present"}));
    }
    let value = json!({
      "calendar":prep["calendar"],"captureSource":prep["captureSource"],"contractVersion":1,
      "controlByteCount":1,"createdAtEpochMilliseconds":prep["createdAtEpochMilliseconds"],
      "invocation":prep["invocation"],"locale":prep["locale"],"observations":observations,
      "operation":prep["operation"],"payloads":prep["payloads"],"pins":prep["pins"],
      "preparationRevision":1,"preset":prep["preset"],"requestID":prep["requestID"],
      "session":{"inputOrdering":"observation-list-then-sequence","maximumAggregateObservationBytes":MAX_AGGREGATE_BYTES,"maximumChunkBytes":MAX_CHUNK_BYTES,"singleFinalize":true,"singleSeal":true},
      "snapshotHash":required.snapshot_hash,"timezone":prep["timezone"]
    });
    value
}

fn new_session(template: Option<&[u8]>) -> MaterializationSession {
    let value = mat_value(template);
    MaterializationSession::new(&canonical(&value)).unwrap()
}

fn resnapshot_materialization(value: &mut Value) {
    let preparation = json!({
        "calendar":value["calendar"],
        "captureSource":value["captureSource"],
        "contractVersion":PREPARATION_INPUT_VERSION,
        "createdAtEpochMilliseconds":value["createdAtEpochMilliseconds"],
        "invocation":value["invocation"],
        "locale":value["locale"],
        "operation":value["operation"],
        "payloads":value["payloads"],
        "pins":value["pins"],
        "preset":value["preset"],
        "requestID":value["requestID"],
        "timezone":value["timezone"]
    });
    let required = prepare(&canonical(&preparation)).unwrap();
    value["snapshotHash"] = json!(required.snapshot_hash);
    for (actual, expected) in value["observations"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .zip(required.observations)
    {
        actual["observationID"] = json!(expected.id);
    }
}

#[test]
fn readiness_is_exact_and_fail_closed() {
    let ready = json!({"kind":"expectedVersions","operation":"newNoteTextLink","versions":{"artifactPlanVersion":ARTIFACT_PLAN_VERSION,"captureMaterializationInputVersion":MATERIALIZATION_INPUT_VERSION,"capturePreparationInputVersion":PREPARATION_INPUT_VERSION,"coreAPIVersion":CORE_API_VERSION,"profileID":PROFILE_ID,"profileVersion":PROFILE_VERSION,"rendererRevision":RENDERER_REVISION,"requiredObservationsVersion":REQUIRED_OBSERVATIONS_VERSION,"toolchainManifestSHA256":TOOLCHAIN_MANIFEST_SHA256}});
    let result = readiness(&canonical(&ready)).unwrap();
    assert!(result.session_permitted);
    assert!(result.mismatch_codes.is_empty());
    let mut bad = ready;
    bad["operation"] = json!("rollingNote");
    bad["versions"]["profileID"] = json!("future");
    bad["versions"]["toolchainManifestSHA256"] = json!("0".repeat(64));
    assert_eq!(
        readiness(&canonical(&bad)).unwrap().mismatch_codes,
        [
            "unsupportedOperation",
            "unsupportedProfile",
            "toolchainManifestMismatch"
        ]
    );
    let mut unknown = bad;
    unknown["unknown"] = json!(true);
    assert_eq!(
        readiness(&canonical(&unknown)),
        Err(CoreError::UnknownField)
    );
}

#[test]
fn preparation_plans_candidates_and_rejects_unshipped_semantics() {
    let prep = prep_value();
    let result = prepare(&canonical(&prep)).unwrap();
    assert_eq!(
        result.observations[0].logical_candidates.as_ref().unwrap()[0],
        ["Inbox", "2023-11-14-11111111.md"]
    );
    assert_eq!(
        result.observations[0].logical_candidates.as_ref().unwrap()[1],
        ["Inbox", "2023-11-14-11111111-2.md"]
    );
    for (path, value, error) in [
        (
            "operation",
            json!("rollingNote"),
            CoreError::UnsupportedOperation,
        ),
        (
            "pins.profileID",
            json!("future"),
            CoreError::UnsupportedProfile,
        ),
        (
            "pins.modelProfileID",
            json!("model"),
            CoreError::UnsupportedModel,
        ),
        (
            "preset.destinationPolicy.expectedCaseSensitivity",
            json!("unknown"),
            CoreError::UnsupportedCollisionSemantics,
        ),
    ] {
        let mut x = prep.clone();
        set(&mut x, path, value);
        assert_eq!(prepare(&canonical(&x)), Err(error));
    }
    let mut asset = prep;
    asset["payloads"][0] = json!({"id":"22222222-2222-4222-8222-222222222222","kind":"asset","length":1,"mediaType":"image/png","originalNamePolicy":"discard","safeExtension":"png","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceID":"55555555-5555-4555-8555-555555555555"});
    assert_eq!(
        prepare(&canonical(&asset)),
        Err(CoreError::UnsupportedOperation)
    );
}

fn set(root: &mut Value, path: &str, value: Value) {
    let mut node = root;
    for part in path
        .split('.')
        .collect::<Vec<_>>()
        .iter()
        .take(path.split('.').count() - 1)
    {
        node = &mut node[*part];
    }
    let last = path.rsplit('.').next().unwrap();
    node[last] = value;
}

#[test]
fn rust_contract_mirror_is_consumed() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/resources/contracts/v1");
    let canonical = root.join("fixtures/core-api/valid-expected-versions.json");
    let bytes = std::fs::read(canonical).expect("required Rust contract mirror fixture");
    let expected: serde_json::Value = serde_json::from_slice(&bytes).expect("valid mirror JSON");
    assert_eq!(expected["kind"], "expectedVersions");
    assert_eq!(expected["versions"]["coreAPIVersion"], CORE_API_VERSION);
    assert!(root.join("core-api/v1/schema.json").is_file());
}

#[test]
fn exact_deterministic_identity_matches_contract_vector() {
    assert_eq!(
        operation_id(uuid("11111111-1111-4111-8111-111111111111"), 0, "newNote")
            .unwrap()
            .to_string(),
        "5d041f20-38ed-5fc4-ab82-000b7164ef0f"
    );
}

#[test]
fn session_orders_seals_drains_verifies_and_becomes_terminal() {
    let mut session = new_session(None);
    let desc = session.seal().unwrap();
    assert_eq!(session.seal(), Err(CoreError::SessionTerminal));
    let artifact = &desc.artifacts[0];
    assert_eq!(
        session.drain(artifact.artifact_id, 1, MAX_CHUNK_BYTES as u64),
        Err(CoreError::DescriptorMismatch)
    );
    let mut valid = new_session(None);
    let desc = valid.seal().unwrap();
    let artifact = &desc.artifacts[0];
    let chunk = valid
        .drain(artifact.artifact_id, 0, MAX_CHUNK_BYTES as u64)
        .unwrap();
    assert!(chunk.eof);
    assert_eq!(
        valid.drain(artifact.artifact_id, 1, MAX_CHUNK_BYTES as u64),
        Err(CoreError::SessionTerminal)
    );
    let hashes = DrainedHashes {
        kind: "drainedArtifactHashes".into(),
        request_id: desc.request_id,
        artifacts: vec![DrainedArtifactHash {
            artifact_id: artifact.artifact_id,
            stream_id: artifact.stream_id,
            length: artifact.length,
            result_sha256: artifact.result_sha256.clone(),
        }],
    };
    let plan = valid.finalize(&hashes).unwrap();
    let value: Value = serde_json::from_slice(&plan).unwrap();
    let hash = value["planHash"].as_str().unwrap();
    assert_ne!(hash, "0".repeat(64));
    let mut zero = value.clone();
    zero["planHash"] = json!("0".repeat(64));
    assert_eq!(hash, sha256_hex(&canonical(&zero)));
    assert_eq!(valid.finalize(&hashes), Err(CoreError::SessionTerminal));
}

#[test]
fn input_stream_bounds_order_hash_cancel_and_post_terminal() {
    let bytes = b"template";
    let id = uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    let mut wrong = new_session(Some(bytes));
    assert_eq!(
        wrong.push_observation(id, 1, bytes, true),
        Err(CoreError::ObservationSequence)
    );
    assert_eq!(wrong.seal(), Err(CoreError::SessionTerminal));
    let mut over = new_session(Some(bytes));
    assert_eq!(
        over.push_observation(id, 0, &vec![0; MAX_CHUNK_BYTES + 1], true),
        Err(CoreError::ChunkTooLarge)
    );
    let mut bad_hash = new_session(Some(bytes));
    assert_eq!(
        bad_hash.push_observation(id, 0, b"templato", true),
        Err(CoreError::InvalidObservationStream)
    );
    let mut ok = new_session(Some(bytes));
    ok.push_observation(id, 0, bytes, true).unwrap();
    assert!(ok.seal().is_ok());
    let mut cancelled = new_session(None);
    cancelled.cancel();
    assert_eq!(cancelled.seal(), Err(CoreError::Cancelled));
    cancelled.cancel();
}

#[test]
fn aggregate_limit_constant_and_streaming_state_are_bounded() {
    assert_eq!(MAX_AGGREGATE_BYTES, 256 << 20);
    assert_eq!(MAX_CHUNK_BYTES, 1 << 20);
    let mut value = mat_value(Some(b"x"));
    value["observations"][1]["length"] = json!(MAX_AGGREGATE_BYTES);
    value["observations"][1]["sha256"] =
        json!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    let mut session = MaterializationSession::new(&canonical(&value)).unwrap();
    let id = uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    let chunk = vec![0; MAX_CHUNK_BYTES];
    session.push_observation(id, 0, &chunk, false).unwrap();
    assert_eq!(session.aggregate_bytes(), MAX_CHUNK_BYTES as u64);
    assert!(std::mem::size_of_val(&session) < 2048);
}

#[test]
fn repeated_newline_template_materializes_without_expanding_the_prefix() {
    let template = vec![b'\n'; 4 * MAX_CHUNK_BYTES];
    let value = mat_value(Some(&template));
    let mut session = MaterializationSession::new(&canonical(&value)).unwrap();
    let id = uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    for (sequence, chunk) in template.chunks(MAX_CHUNK_BYTES).enumerate() {
        session
            .push_observation(
                id,
                u32::try_from(sequence).unwrap(),
                chunk,
                sequence + 1 == template.len() / MAX_CHUNK_BYTES,
            )
            .unwrap();
    }
    drop(template);
    let descriptor = session.seal().unwrap().artifacts.remove(0);
    assert!(descriptor.length < 1024);
    let output = session
        .drain(descriptor.artifact_id, 0, MAX_CHUNK_BYTES as u64)
        .unwrap();
    assert!(output.eof);
    assert!(
        String::from_utf8(output.bytes)
            .unwrap()
            .starts_with("---\nsource:")
    );
}

#[test]
fn failed_seal_is_terminal_and_drain_honors_caller_bound() {
    let mut invalid = mat_value(None);
    invalid["payloads"][0]["text"] = json!("\n\r\n");
    invalid["payloads"].as_array_mut().unwrap().truncate(1);
    resnapshot_materialization(&mut invalid);
    let bytes = canonical(&invalid);
    let mut session = MaterializationSession::new(&bytes).unwrap();
    assert_eq!(session.seal(), Err(CoreError::InvalidRendering));
    assert_eq!(session.seal(), Err(CoreError::SessionTerminal));

    let mut zero = new_session(None);
    let descriptor = zero.seal().unwrap().artifacts.remove(0);
    assert_eq!(
        zero.drain(descriptor.artifact_id, 0, 0),
        Err(CoreError::ChunkTooLarge)
    );
    assert_eq!(
        zero.drain(descriptor.artifact_id, 0, 1),
        Err(CoreError::SessionTerminal)
    );

    let mut bounded = new_session(None);
    let descriptor = bounded.seal().unwrap().artifacts.remove(0);
    let chunk = bounded.drain(descriptor.artifact_id, 0, 7).unwrap();
    assert!(chunk.bytes.len() <= 7);
    assert!(!chunk.eof);
}

#[test]
fn prepared_chunk_sequence_boundary_fails_before_invalid_metadata() {
    let mut input = mat_value(None);
    input["payloads"] = json!(
        (0..5)
            .map(|index| json!({
                "id": format!("00000000-0000-4000-8000-{index:012}"),
                "kind": "text",
                "text": "x".repeat(65_536)
            }))
            .collect::<Vec<_>>()
    );
    resnapshot_materialization(&mut input);
    let mut session = MaterializationSession::new(&canonical(&input)).unwrap();
    let descriptor = session.seal().unwrap().artifacts.remove(0);
    for sequence in 0..=MAX_PREPARED_CHUNK_SEQUENCE {
        let chunk = session.drain(descriptor.artifact_id, sequence, 1).unwrap();
        assert_eq!(chunk.sequence, sequence);
        assert!(!chunk.eof);
    }
    assert_eq!(
        session.drain(descriptor.artifact_id, MAX_PREPARED_CHUNK_SEQUENCE + 1, 1,),
        Err(CoreError::PreparedChunkSequenceOutOfRange)
    );
    assert_eq!(
        session.drain(descriptor.artifact_id, MAX_PREPARED_CHUNK_SEQUENCE + 1, 1,),
        Err(CoreError::SessionTerminal)
    );
}

#[test]
fn preparation_enforces_normative_bounds_enums_and_ordering() {
    for (path, value, error) in [
        ("captureSource", json!("future"), CoreError::InvalidEnum),
        (
            "createdAtEpochMilliseconds",
            json!(4_102_444_800_001_i64),
            CoreError::IntegerOutOfRange,
        ),
        (
            "invocation.locationOutcome",
            json!("future"),
            CoreError::InvalidEnum,
        ),
        (
            "preset.routePolicy.noteNameTemplate",
            json!("x".repeat(1_025)),
            CoreError::StringTooLarge,
        ),
        (
            "preset.destinationPolicy.capabilityReference",
            json!("x".repeat(129)),
            CoreError::StringTooLarge,
        ),
        (
            "preset.snapshotHash",
            json!("A".repeat(64)),
            CoreError::InvalidHash,
        ),
    ] {
        let mut input = prep_value();
        set(&mut input, path, value);
        assert_eq!(prepare(&canonical(&input)), Err(error), "{path}");
    }
    let mut payload = prep_value();
    payload["payloads"][0]["text"] = json!("x".repeat(65_537));
    assert_eq!(
        prepare(&canonical(&payload)),
        Err(CoreError::StringTooLarge)
    );
    let mut fields = prep_value();
    fields["preset"]["metadataPolicy"]["orderedFields"] = json!(
        (0..129)
            .map(|index| json!({"name":format!("f{index}"),"value":"v"}))
            .collect::<Vec<_>>()
    );
    assert_eq!(prepare(&canonical(&fields)), Err(CoreError::ArrayTooLarge));
}

#[test]
fn paths_reject_traversal_and_occupancy_order_does_not_change_selection() {
    for segment in [".", "..", "bad/segment", "bad\\segment", "bad\0segment"] {
        let mut input = prep_value();
        input["preset"]["routePolicy"]["logicalFolder"] = json!([segment]);
        assert!(matches!(
            prepare(&canonical(&input)),
            Err(CoreError::InvalidPath)
        ));
    }
    let mut first = mat_value(None);
    let paths = json!([
        ["Inbox", "2023-11-14-11111111-2.md"],
        ["Inbox", "2023-11-14-11111111.md"]
    ]);
    first["observations"][0]["logicalPaths"] = paths.clone();
    first["observations"][0]["orderedSetHash"] = json!(sha256_hex(&canonical(&paths)));
    let mut second = first.clone();
    let reversed = json!([
        ["Inbox", "2023-11-14-11111111.md"],
        ["Inbox", "2023-11-14-11111111-2.md"]
    ]);
    second["observations"][0]["logicalPaths"] = reversed.clone();
    second["observations"][0]["orderedSetHash"] = json!(sha256_hex(&canonical(&reversed)));
    let a = MaterializationSession::new(&canonical(&first))
        .unwrap()
        .seal()
        .unwrap();
    let b = MaterializationSession::new(&canonical(&second))
        .unwrap()
        .seal()
        .unwrap();
    assert_eq!(a.artifacts[0].artifact_id, b.artifacts[0].artifact_id);
}

#[test]
fn ordered_frontmatter_is_preserved_by_rust_materialization() {
    let mut input = mat_value(Some(b"Prefix\r\n"));
    input["preset"]["metadataPolicy"]["orderedFields"] = json!([
        {"name":"zeta","value":"two"},
        {"name":"alpha","value":"one"}
    ]);
    resnapshot_materialization(&mut input);
    let bytes = canonical(&input);
    let mut session = MaterializationSession::new(&bytes).unwrap();
    session
        .push_observation(
            uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            0,
            b"Prefix\r\n",
            true,
        )
        .unwrap();
    let descriptor = session.seal().unwrap().artifacts.remove(0);
    let chunk = session
        .drain(descriptor.artifact_id, 0, MAX_CHUNK_BYTES as u64)
        .unwrap();
    let rendered = String::from_utf8(chunk.bytes).unwrap();
    assert!(rendered.starts_with("---\nzeta: \"two\"\nalpha: \"one\"\n---\n\nPrefix"));
    assert!(!rendered.contains('\r'));
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Corpus {
    #[serde(rename = "corpusVersion")]
    version: u32,
    producer: Producer,
    cases: Vec<OracleCase>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Producer {
    name: String,
    source_revision: String,
    #[serde(rename = "oracleSourceSHA256")]
    oracle_source_sha256: String,
    production_consumers: Vec<Consumer>,
    swift_compiler_identity: String,
    xcode_identity: String,
    #[serde(rename = "toolchainManifestSHA256")]
    toolchain_manifest_sha256: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Consumer {
    name: String,
    path: String,
    sha256: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OracleCase {
    id: String,
    request: OracleRequest,
    expected: Option<Expected>,
    expected_error: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OracleRequest {
    #[serde(rename = "requestID")]
    request_id: String,
    created_at_epoch_milliseconds: i64,
    timezone: String,
    source: String,
    payloads: Vec<OraclePayload>,
    logical_folder: Vec<String>,
    note_name_template: String,
    occupied_paths: Vec<Vec<String>>,
    entry_prefix: String,
    entry_suffix: String,
    frontmatter: Vec<Field>,
    retry_marker: bool,
    final_newline: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OraclePayload {
    kind: String,
    text: Option<String>,
    url: Option<String>,
    label: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Field {
    name: String,
    value: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Expected {
    logical_path: Vec<String>,
    bytes_base64: String,
    sha256: String,
}

fn oracle_preparation(request: &OracleRequest) -> Value {
    let mut prep = prep_value();
    prep["requestID"] = json!(request.request_id);
    prep["createdAtEpochMilliseconds"] = json!(request.created_at_epoch_milliseconds);
    prep["timezone"] = json!(request.timezone);
    prep["captureSource"] = json!(request.source);
    prep["preset"]["routePolicy"]["logicalFolder"] = json!(request.logical_folder);
    prep["preset"]["routePolicy"]["noteNameTemplate"] = json!(request.note_name_template);
    prep["preset"]["metadataPolicy"]["orderedFields"] = json!(
        request
            .frontmatter
            .iter()
            .map(|field| json!({"name":field.name,"value":field.value}))
            .collect::<Vec<_>>()
    );
    prep["preset"]["metadataPolicy"]["templatePolicy"] = json!(if request.entry_prefix.is_empty()
        && request.entry_suffix.is_empty()
    {
        "none"
    } else {
        "frozenObservation"
    });
    prep["preset"]["retryMarkerPolicy"] = json!(if request.retry_marker {
        "voxCaptureCommentV1"
    } else {
        "none"
    });
    prep["preset"]["metadataPolicy"]["finalNewline"] = json!(request.final_newline);
    prep["payloads"] = json!(request
        .payloads
        .iter()
        .enumerate()
        .map(|(index, payload)| if payload.kind == "text" {
            json!({"id":format!("00000000-0000-4000-8000-{index:012}"),"kind":"text","text":payload.text})
        } else {
            json!({"id":format!("00000000-0000-4000-8000-{index:012}"),"kind":"link","url":payload.url,"label":payload.label})
        })
        .collect::<Vec<_>>());
    prep
}

fn run_oracle_case(request: &OracleRequest) -> Result<(Vec<String>, Vec<u8>), CoreError> {
    // M2's frozen-template observation is the new-note entry prefix exercised by the
    // shipped Apple pipeline. Entry suffix expansion remains outside this Phase A subset.
    assert!(request.entry_suffix.is_empty());
    let prep = oracle_preparation(request);
    let required = prepare(&canonical(&prep))?;
    let paths = request.occupied_paths.clone();
    let path_hash = sha256_hex(&canonical_bytes(&paths)?);
    let template = request.entry_prefix.clone();
    let has_template = !template.is_empty();
    let mut observations = vec![json!({
        "kind":"candidateOccupancy",
        "logicalPaths":paths,
        "observationID":required.observations[0].id,
        "orderedSetHash":path_hash,
        "status":"present"
    })];
    if has_template {
        observations.push(json!({
            "byteStreamID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "kind":"frozenTemplate",
            "length":template.len(),
            "observationID":required.observations[1].id,
            "sha256":sha256_hex(template.as_bytes()),
            "status":"present"
        }));
    }
    let materialization = json!({
        "calendar":prep["calendar"],"captureSource":prep["captureSource"],"contractVersion":1,
        "controlByteCount":1,"createdAtEpochMilliseconds":prep["createdAtEpochMilliseconds"],
        "invocation":prep["invocation"],"locale":prep["locale"],"observations":observations,
        "operation":prep["operation"],"payloads":prep["payloads"],"pins":prep["pins"],
        "preparationRevision":1,"preset":prep["preset"],"requestID":prep["requestID"],
        "session":{"inputOrdering":"observation-list-then-sequence","maximumAggregateObservationBytes":MAX_AGGREGATE_BYTES,"maximumChunkBytes":MAX_CHUNK_BYTES,"singleFinalize":true,"singleSeal":true},
        "snapshotHash":required.snapshot_hash,"timezone":prep["timezone"]
    });
    let mut session = MaterializationSession::new(&canonical(&materialization))?;
    if has_template {
        session.push_observation(
            uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            0,
            template.as_bytes(),
            true,
        )?;
    }
    let descriptors = session.seal()?;
    let descriptor = &descriptors.artifacts[0];
    let mut bytes = Vec::new();
    let mut sequence = 0;
    loop {
        let chunk = session.drain(descriptor.artifact_id, sequence, 17)?;
        bytes.extend_from_slice(&chunk.bytes);
        if chunk.eof {
            break;
        }
        sequence += 1;
    }
    let plan = session.finalize(&DrainedHashes {
        kind: "drainedArtifactHashes".into(),
        request_id: descriptors.request_id,
        artifacts: vec![DrainedArtifactHash {
            artifact_id: descriptor.artifact_id,
            stream_id: descriptor.stream_id,
            length: descriptor.length,
            result_sha256: descriptor.result_sha256.clone(),
        }],
    })?;
    assert!(!plan.is_empty());
    let value: Value = serde_json::from_slice(&plan).unwrap();
    Ok((
        value["artifacts"][0]["logicalPath"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item.as_str().unwrap().to_owned())
            .collect(),
        bytes,
    ))
}

#[test]
fn swift_oracle_corpus_matches_production_sessions_and_executes_negatives() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..");
    let path = root.join("Packages/vox-core-rust/tests/fixtures/swift-m2-oracle-v1.json");
    let corpus: Corpus = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert_eq!(corpus.version, 1);
    assert_eq!(corpus.producer.name, "VoxboardM2Oracle");
    assert_eq!(corpus.producer.source_revision.len(), 40);
    assert!(!corpus.producer.swift_compiler_identity.is_empty());
    assert!(!corpus.producer.xcode_identity.is_empty());
    assert_eq!(
        corpus.producer.toolchain_manifest_sha256,
        sha256_hex(&fs::read(root.join("toolchains/android-wear-shared-core.json")).unwrap())
    );
    let mut expected_consumer_paths =
        fs::read_dir(root.join("Packages/VoxboardShared/Sources/VoxboardCaptureCore"))
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "swift")
            })
            .map(|path| {
                path.strip_prefix(&root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect::<Vec<_>>();
    expected_consumer_paths.sort();
    assert_eq!(
        corpus
            .producer
            .production_consumers
            .iter()
            .map(|consumer| consumer.path.clone())
            .collect::<Vec<_>>(),
        expected_consumer_paths
    );
    for consumer in &corpus.producer.production_consumers {
        assert_eq!(
            consumer.name,
            std::path::Path::new(&consumer.path)
                .file_stem()
                .unwrap()
                .to_string_lossy()
        );
        assert_eq!(
            consumer.sha256,
            sha256_hex(&fs::read(root.join(&consumer.path)).unwrap())
        );
    }
    assert_eq!(
        corpus.producer.oracle_source_sha256,
        sha256_hex(
            &fs::read(root.join("Packages/VoxboardShared/Sources/VoxboardM2Oracle/main.swift"))
                .unwrap()
        )
    );
    let mut negative_count = 0;
    for case in corpus.cases {
        let actual = run_oracle_case(&case.request);
        match (case.expected, case.expected_error) {
            (Some(expected), None) => {
                let (path, bytes) = actual.unwrap_or_else(|error| panic!("{}: {error:?}", case.id));
                assert_eq!(path, expected.logical_path, "{} path", case.id);
                assert_eq!(sha256_hex(&bytes), expected.sha256, "{} hash", case.id);
                assert_eq!(base64(&bytes), expected.bytes_base64, "{} bytes", case.id);
            }
            (None, Some(expected_error)) => {
                negative_count += 1;
                assert_eq!(
                    actual.unwrap_err().code(),
                    expected_error,
                    "{} error",
                    case.id
                );
            }
            _ => panic!("{} has incoherent oracle expectations", case.id),
        }
    }
    assert!(negative_count >= 5);
}

fn base64(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in data.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(if c.len() > 1 {
            T[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

#[test]
fn errors_never_echo_user_content_paths_or_hashes() {
    let secret = "sensitive-user-content";
    let malformed = format!("{{\"{secret}\":");
    let error = parse_control::<Value>(malformed.as_bytes()).unwrap_err();
    assert!(!error.to_string().contains(secret));
    for error in [
        CoreError::InvalidPath,
        CoreError::DrainedHashMismatch,
        CoreError::InvalidRendering,
    ] {
        assert!(!error.to_string().contains(secret));
    }
}
