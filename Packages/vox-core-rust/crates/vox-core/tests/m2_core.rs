use std::{fs, path::PathBuf};

use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;
use vox_core::{
    ARTIFACT_PLAN_VERSION, CORE_API_VERSION, CORE_VERSION, CoreError, DrainedArtifactHash,
    DrainedHashes, MATERIALIZATION_INPUT_VERSION, MAX_AGGREGATE_BYTES, MAX_CHUNK_BYTES,
    MaterializationInput, MaterializationSession, PREPARATION_INPUT_VERSION, PROFILE_ID,
    PROFILE_VERSION, RENDERER_REVISION, REQUIRED_OBSERVATIONS_VERSION, canonical_bytes,
    materialize, operation_id, parse_control, path_candidates, prepare, readiness, sha256_hex,
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

#[test]
fn readiness_is_exact_and_fail_closed() {
    let ready = json!({"kind":"expectedVersions","operation":"newNoteTextLink","versions":{"artifactPlanVersion":ARTIFACT_PLAN_VERSION,"captureMaterializationInputVersion":MATERIALIZATION_INPUT_VERSION,"capturePreparationInputVersion":PREPARATION_INPUT_VERSION,"coreAPIVersion":CORE_API_VERSION,"profileID":PROFILE_ID,"profileVersion":PROFILE_VERSION,"rendererRevision":RENDERER_REVISION,"requiredObservationsVersion":REQUIRED_OBSERVATIONS_VERSION}});
    let result = readiness(&canonical(&ready)).unwrap();
    assert!(result.session_permitted);
    assert!(result.mismatch_codes.is_empty());
    let mut bad = ready;
    bad["operation"] = json!("rollingNote");
    bad["versions"]["profileID"] = json!("future");
    assert_eq!(
        readiness(&canonical(&bad)).unwrap().mismatch_codes,
        ["unsupportedOperation", "unsupportedProfile"]
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
    asset["payloads"][0] = json!({"id":"22222222-2222-4222-8222-222222222222","kind":"asset","length":1,"mediaType":"image/png","originalNamePolicy":"discard","safeExtension":"png","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sourceId":"55555555-5555-4555-8555-555555555555"});
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
        session.drain(artifact.artifact_id, 1),
        Err(CoreError::DescriptorMismatch)
    );
    let mut valid = new_session(None);
    let desc = valid.seal().unwrap();
    let artifact = &desc.artifacts[0];
    let chunk = valid.drain(artifact.artifact_id, 0).unwrap();
    assert!(chunk.eof);
    assert_eq!(
        valid.drain(artifact.artifact_id, 1),
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

#[derive(Deserialize)]
struct Corpus {
    cases: Vec<OracleCase>,
}
#[derive(Deserialize)]
struct OracleCase {
    id: String,
    request: OracleRequest,
    expected: Option<Expected>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
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
    frontmatter: Vec<Field>,
    retry_marker: bool,
    final_newline: bool,
}
#[derive(Deserialize)]
struct OraclePayload {
    kind: String,
    text: Option<String>,
    url: Option<String>,
    label: Option<String>,
}
#[derive(Deserialize)]
struct Field {
    name: String,
    value: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expected {
    logical_path: Vec<String>,
    bytes_base64: String,
    sha256: String,
}

#[test]
fn swift_oracle_corpus_matches_raw_paths_bytes_and_hashes() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/swift-m2-oracle-v1.json");
    let corpus: Corpus = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    for case in corpus
        .cases
        .into_iter()
        .filter(|case| case.expected.is_some())
    {
        let r = case.request;
        let mut prep = prep_value();
        prep["requestID"] = json!(r.request_id);
        prep["createdAtEpochMilliseconds"] = json!(r.created_at_epoch_milliseconds);
        prep["timezone"] = json!(r.timezone);
        prep["captureSource"] = json!(r.source);
        prep["preset"]["routePolicy"]["logicalFolder"] = json!(r.logical_folder);
        prep["preset"]["routePolicy"]["noteNameTemplate"] = json!(r.note_name_template);
        prep["preset"]["metadataPolicy"]["orderedFields"] = json!(
            r.frontmatter
                .into_iter()
                .map(|x| json!({"name":x.name,"value":x.value}))
                .collect::<Vec<_>>()
        );
        prep["preset"]["retryMarkerPolicy"] = json!(if r.retry_marker {
            "voxCaptureCommentV1"
        } else {
            "none"
        });
        prep["preset"]["metadataPolicy"]["finalNewline"] = json!(r.final_newline);
        prep["payloads"]=json!(r.payloads.into_iter().enumerate().map(|(i,p)|if p.kind=="text"{json!({"id":format!("00000000-0000-4000-8000-{i:012}"),"kind":"text","text":p.text.unwrap()})}else{json!({"id":format!("00000000-0000-4000-8000-{i:012}"),"kind":"link","url":p.url.unwrap(),"label":p.label.unwrap()})}).collect::<Vec<_>>());
        let input: vox_core::PreparationInput = parse_control(&canonical(&prep)).unwrap();
        let candidates = path_candidates(&input).unwrap();
        let occupied: std::collections::BTreeSet<_> = r.occupied_paths.into_iter().collect();
        let path = candidates
            .into_iter()
            .find(|x| !occupied.contains(x))
            .unwrap();
        let mut mat: MaterializationInput = serde_json::from_value(mat_value(None)).unwrap();
        mat.request_id = input.request_id;
        mat.created_at_epoch_milliseconds = input.created_at_epoch_milliseconds;
        mat.timezone = input.timezone.clone();
        mat.capture_source = input.capture_source.clone();
        mat.payloads = input.payloads.clone();
        mat.preset = input.preset.clone();
        mat.observations[0] = vox_core::ObservationResult::CandidateOccupancy {
            observation_id: prepare(&canonical(&prep)).unwrap().observations[0].id,
            status: "present".into(),
            logical_paths: occupied.into_iter().collect(),
            ordered_set_hash: String::new(),
        };
        let (_, mut bytes) = materialize(&mat, None).unwrap();
        if !r.entry_prefix.is_empty() {
            let rendered = vox_core::render_tokens(
                &r.entry_prefix,
                r.created_at_epoch_milliseconds,
                &r.timezone,
                input.request_id,
                &r.source,
            )
            .unwrap();
            let body = String::from_utf8(bytes).unwrap();
            let (front, rest) = body
                .strip_prefix("---\n")
                .and_then(|x| x.split_once("\n---\n\n"))
                .map_or(("", body.as_str()), |(a, b)| (a, b));
            bytes = if front.is_empty() {
                let rendered = rendered.trim_matches(['\r', '\n']);
                if rendered.is_empty() {
                    rest.as_bytes().to_vec()
                } else if rendered.starts_with("---\n") && rendered.ends_with("\n---") {
                    format!("{rendered}\n\n{rest}").into_bytes()
                } else {
                    format!("{rendered}{rest}").into_bytes()
                }
            } else {
                format!(
                    "---\n{front}\n---\n\n{}\n{}",
                    rendered.trim_matches(['\r', '\n']),
                    rest
                )
                .into_bytes()
            };
        }
        let expected = case.expected.unwrap();
        assert_eq!(path, expected.logical_path, "{} path", case.id);
        assert_eq!(sha256_hex(&bytes), expected.sha256, "{} hash", case.id);
        assert_eq!(base64(&bytes), expected.bytes_base64, "{} bytes", case.id);
    }
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
