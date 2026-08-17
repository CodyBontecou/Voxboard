import json,pathlib,copy
B=pathlib.Path('Packages/contracts'); F=B/'fixtures'
def dump(fam,name,v):
 p=F/fam/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,indent=2,sort_keys=True)+'\n')
U=['11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444','55555555-5555-4555-8555-555555555555','66666666-6666-4666-8666-666666666666','77777777-7777-4777-8777-777777777777','88888888-8888-4888-8888-888888888888','99999999-9999-4999-8999-999999999999']
H=['0'*64,'1'*64,'2'*64,'3'*64]
pins={'coreVersion':'vox-core-contract-only','rendererRevision':'swift-legacy-m0','profileID':'apple-parity-v1','profileVersion':1,'modelProfileID':None,'modelRevision':None}
route={'attachmentFolder':['Assets'],'collisionPolicy':'reuseIfHashMatches','extensionPolicy':'markdownDotMd','logicalFolder':['Synthetic Vault','Inbox'],'noteNameTemplate':'capture-{id}.md'}
meta={'finalNewline':True,'frontmatterMode':'merge','lineEnding':'lf','orderedFields':[{'name':'source','value':'synthetic'}],'templatePolicy':'frozenObservation'}
dest={'capabilityClass':'userVault','capabilityReference':'synthetic-vault-capability','expectedCaseSensitivity':'unknown'}
preset={'destinationPolicy':dest,'id':U[2],'metadataPolicy':meta,'retryMarkerPolicy':'voxCaptureCommentV1','revision':7,'routePolicy':route,'snapshotHash':H[0],'templateFreezePoint':'firstPreparation'}
prep={'calendar':'gregorian','captureSource':'app','contractVersion':1,'createdAtEpochMilliseconds':1700000000000,'invocation':{'locationOutcome':'notRequested','originRecordingID':None,'sequence':1},'locale':'en-US','operation':'newNote','payloads':[{'id':U[1],'kind':'text','text':'Synthetic capture text.'},{'id':U[3],'kind':'link','label':'Synthetic link','url':'https://example.invalid/synthetic'},{'id':U[4],'kind':'asset','length':32,'mediaType':'audio/wav','originalNamePolicy':'discard','safeExtension':'wav','sha256':H[1],'sourceID':U[5]}],'pins':pins,'preset':preset,'requestID':U[0],'timezone':'America/Los_Angeles'}
for p in F.glob('*/*.json'): p.unlink()
dump('capture-preparation-input','valid-complete.json',prep)
x=copy.deepcopy(prep);x['payloads'][0]['unexpected']=True;dump('capture-preparation-input','invalid-unknown-payload-field.json',x)
x=copy.deepcopy(prep);x['payloads'][1]['kind']='text';dump('capture-preparation-input','invalid-tag-payload-mismatch.json',x)
x=copy.deepcopy(prep);x['preset']['routePolicy']['logicalFolder'][0]='..';dump('capture-preparation-input','invalid-unsafe-path.json',x)
x=copy.deepcopy(prep);x['payloads'][2]['length']=1073741825;dump('capture-preparation-input','invalid-asset-oversize.json',x)
req={'aggregateMaximumBytes':268435456,'contractVersion':1,'observations':[{'id':U[3],'kind':'candidateOccupancy','logicalCandidates':[['Synthetic Vault','Inbox','capture.md']]},{'id':U[4],'kind':'frozenTemplate','maximumBytes':268435456,'required':False,'templateCapabilityReference':'synthetic-template'},{'id':U[5],'kind':'existingNote','logicalPath':['Synthetic Vault','Inbox','capture.md'],'maximumBytes':268435456,'required':True},{'id':U[6],'kind':'stagedAssetMetadata','sourceIDs':[U[5]]}],'ordering':'listed','preparationRevision':1,'requestID':U[0],'snapshotHash':H[0]}
dump('required-observations','valid-all-kinds.json',req)
x=copy.deepcopy(req);x['observations'][0]['maximumBytes']=1;dump('required-observations','invalid-tag-request-mismatch.json',x)
x=copy.deepcopy(req);x['observations'].append(copy.deepcopy(x['observations'][0]));dump('required-observations','invalid-duplicate-id.json',x)
mat={'calendar':'gregorian','captureSource':'app','contractVersion':1,'controlByteCount':4096,'createdAtEpochMilliseconds':1700000000000,'invocation':prep['invocation'],'locale':'en-US','observations':[{'kind':'candidateOccupancy','logicalPaths':[['Synthetic Vault','Inbox','capture.md']],'observationID':U[3],'orderedSetHash':H[1],'status':'present'},{'byteStreamID':None,'kind':'frozenTemplate','length':0,'observationID':U[4],'sha256':H[0],'status':'absent'},{'byteStreamID':U[7],'kind':'existingNote','length':25,'logicalPath':['Synthetic Vault','Inbox','capture.md'],'observationID':U[5],'sha256':H[2],'status':'present'},{'assets':[{'length':32,'mediaType':'audio/wav','sha256':H[1],'sourceID':U[5]}],'kind':'stagedAssetMetadata','observationID':U[6],'orderedSetHash':H[3],'status':'present'}],'operation':'newNote','payloads':prep['payloads'],'pins':pins,'preparationRevision':1,'preset':preset,'requestID':U[0],'session':{'inputOrdering':'observation-list-then-sequence','maximumAggregateObservationBytes':268435456,'maximumChunkBytes':1048576,'singleFinalize':True,'singleSeal':True},'snapshotHash':H[0],'timezone':'America/Los_Angeles'}
dump('capture-materialization-input','valid-complete.json',mat)
x=copy.deepcopy(mat);x['observations'][1]['status']='present';dump('capture-materialization-input','invalid-present-template-null-stream.json',x)
x=copy.deepcopy(mat);x['observations'][0]['kind']='existingNote';dump('capture-materialization-input','invalid-tag-observation-mismatch.json',x)
x=copy.deepcopy(mat);x['controlByteCount']=1048577;dump('capture-materialization-input','invalid-control-oversize.json',x)
x=copy.deepcopy(mat);x['session']['maximumChunkBytes']=1048575;dump('capture-materialization-input','invalid-session-chunk-limit.json',x)
plan={'artifacts':[{'artifactID':U[4],'commitSequence':0,'equivalenceRule':'sameSourceAndResultHash','expectedExistingPolicy':'absent','expectedExistingSHA256':None,'journalFrontier':'attachmentVerified','kind':'attachment','logicalPath':['Synthetic Vault','Assets','audio.wav'],'mediaType':'audio/wav','operationID':U[6],'receiptKind':'attachmentCommit','resultLength':32,'resultSHA256':H[1],'sourceID':U[5],'sourceLength':32,'sourceMediaType':'audio/wav','sourceSHA256':H[1]},{'artifactID':U[7],'commitSequence':1,'equivalenceRule':'exactBytes','expectedExistingPolicy':'hashMatch','expectedExistingSHA256':H[2],'expectedOriginalSHA256':H[2],'journalFrontier':'noteVerified','kind':'note','logicalPath':['Synthetic Vault','Inbox','capture.md'],'mediaType':'text/markdown; charset=utf-8','operationID':U[8],'preparedStreamID':U[3],'receiptKind':'noteCommit','resultLength':25,'resultSHA256':H[3],'writeMode':'append'}],'contractVersion':1,'diagnostics':[{'code':'materialized','fieldPath':'$','severity':'info'}],'operation':'existingNoteAppend','pins':pins,'planHash':H[0],'preparedByteDelivery':{'finalJSONDuplicatesBytes':False,'maximumChunkBytes':1048576,'mode':'drainedImmutableArtifacts'},'requestID':U[0],'retryMarker':{'placement':'entrySuffixBeforeFinalNewline','policy':'voxCaptureCommentV1','syntax':'<!-- vox-capture:{lowercase-uuid} -->'},'warnings':[]}
dump('artifact-plan','valid-complete.json',plan)
x=copy.deepcopy(plan);x['artifacts'][0]['kind']='note';dump('artifact-plan','invalid-tag-artifact-mismatch.json',x)
x=copy.deepcopy(plan);x['retryMarker']['syntax']='<!-- vox-operation:{lowercase-uuid} -->';dump('artifact-plan','invalid-marker-syntax.json',x)
x=copy.deepcopy(plan);x['artifacts'][1]['commitSequence']=0;dump('artifact-plan','invalid-commit-order.json',x)
x=copy.deepcopy(plan);x['preparedByteDelivery']['finalJSONDuplicatesBytes']=True;dump('artifact-plan','invalid-final-json-byte-duplication.json',x)
# Wear fixtures from schema variant examples.
base={'protocolVersion':1,'messageID':U[1],'recordingID':U[0],'senderInstallationID':U[2],'deviceID':U[3],'epoch':1,'revision':1,'correlationID':U[4]}
portable={'destinationCapabilityReference':'synthetic-vault-capability','localASRPolicy':'requiredLocal','locationPolicy':'excluded','metadataPolicy':meta,'operation':'newNote','recordingOnlyFilenamePolicyReference':None,'recordingOnlyFolderPolicyReference':None,'routePolicy':route}
portable_hash=__import__('hashlib').sha256((json.dumps(portable,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()).hexdigest()
payloads={
'capabilityHello':{'supportedVersions':[1],'capabilities':['assets','channels']},'unsupportedVersion':{'reasonCode':'unsupportedProtocolVersion','receivedVersion':2,'supportedVersions':[1]},'presetInventory':{'inventoryRevision':7,'presets':[{'presetID':U[5],'revision':7,'snapshotHash':portable_hash}]},'presetSnapshot':{'portablePolicy':portable,'presetID':U[5],'presetRevision':7,'schemaVersion':1,'snapshotHash':portable_hash},'recordingMetadata':{'createdAtEpochMilliseconds':1700000000000,'localASRPolicy':'requiredLocal','locationPolicy':'excluded','mode':'transcript','presetID':U[5],'presetRevision':7,'presetSnapshotHash':portable_hash,'recordingOnlyFilenamePolicyReference':None,'recordingOnlyFolderPolicyReference':None,'timezone':'UTC'},'assetManifest':{'assetID':U[6],'length':1048576,'mediaType':'audio/wav','sha256':H[1],'transport':'dataAsset'},'transferFrontier':{'assetID':U[6],'assetLength':1048576,'assetSHA256':H[1],'chunkLength':1048576,'chunkSequence':0,'durableOffset':1048576,'frontierRevision':1},'reconciliationSummary':{'pendingActionCorrelationIDs':[],'recordings':[{'lastRevision':1,'recordingID':U[0],'state':'localRecorded'}]},'transferReceipt':{'assetID':U[6],'durableOffset':1048576,'frontierRevision':1,'transportReceiptID':U[7]},'phoneIngested':{'assetLength':1048576,'assetSHA256':H[1],'durableReceiptID':U[7],'phonePackageHash':H[2]},'vaultCommitted':{'destinationReceiptID':U[7],'phoneIngestedCorrelationID':U[4],'verifiedArtifactHash':H[3],'verifiedArtifactLength':1048576},'terminalFailure':{'failedMessageCorrelationID':U[4],'mediaRetained':True,'reasonCode':'permanentDestinationFailure'},'discarded':{'actionReceiptID':U[7],'discardReason':'explicitUserDiscard','mediaDeletionPersisted':True},'sourceDeletionAuthorized':{'authorizationThreshold':'vaultCommitted','durableObservationReceiptID':U[7],'vaultCommitCorrelationID':U[4]},'reassign':{'actionID':U[7],'targetCapabilityReference':'synthetic-vault-2','userConfirmed':True},'retry':{'actionID':U[7],'retryFromRevision':1,'userInitiated':True},'discard':{'actionID':U[7],'retentionOverride':'explicitDiscard','userConfirmed':True}}
replay={'capabilityHello':'idempotent','unsupportedVersion':'terminal','presetInventory':'newerRevisionWins','presetSnapshot':'newerRevisionWins','recordingMetadata':'newerRevisionWins','assetManifest':'newerRevisionWins','transferFrontier':'newerRevisionWins','reconciliationSummary':'newerRevisionWins','transferReceipt':'idempotent','phoneIngested':'idempotent','vaultCommitted':'terminal','terminalFailure':'terminal','discarded':'terminal','sourceDeletionAuthorized':'terminal','reassign':'idempotent','retry':'idempotent','discard':'terminal'}
messages={}
for i,(kind,pay) in enumerate(payloads.items()):
 e={**base,'messageID':f'{i+1:08x}-1111-4111-8111-111111111111','messageKind':kind,'payload':pay,'replayRule':replay[kind],'revision':i+1};messages[kind]=e;dump('wearable-protocol',f'valid-{kind}.json',e)
for kind,field,bad,name in [('recordingMetadata','mode','recordingOnly','invalid-recording-mode-policy.json'),('transferFrontier','chunkLength',1048577,'invalid-frontier-chunk-oversize.json'),('sourceDeletionAuthorized','authorizationThreshold','phoneIngested','invalid-deletion-threshold.json')]:
 x=copy.deepcopy(messages[kind]);x['payload'][field]=bad;dump('wearable-protocol',name,x)
x=copy.deepcopy(messages['phoneIngested']);x['payload']['verifiedArtifactHash']=H[3];dump('wearable-protocol','invalid-kind-payload-cross-contamination.json',x)
# Correlated reducer traces. Expected replay dispositions are executable assertions.
def event(kind,rev,disposition='accepted',corr=U[4],installation=U[2],epoch=1,message_id=None,recording=U[0],device=U[3]):
 e=copy.deepcopy(messages[kind]);e.update(revision=rev,correlationID=corr,senderInstallationID=installation,epoch=epoch,recordingID=recording,deviceID=device)
 if message_id: e['messageID']=message_id
 return {'envelope':e,'expectedDisposition':disposition}
def identity(e):
 x=e['envelope'];return {k:x[k] for k in ('senderInstallationID','deviceID','recordingID','epoch','correlationID')}
def trace_file(name,events,state,deletion=False,final_event=None,trace_id=U[8]):
 final_event=final_event or events[-1]
 dump('wearable-protocol-trace',name,{'events':events,'expectedDeletionPermitted':deletion,'expectedFinalRecordingIdentity':identity(final_event),'expectedFinalState':state,'traceID':trace_id,'traceVersion':1})
def frozen_prefix(recording_only=False):
 inventory=event('presetInventory',1); snapshot=event('presetSnapshot',2); metadata=event('recordingMetadata',3)
 if recording_only:
  policy=snapshot['envelope']['payload']['portablePolicy'];policy.update(localASRPolicy='disabled',locationPolicy='excluded',recordingOnlyFolderPolicyReference='recording-only-folder-v1',recordingOnlyFilenamePolicyReference='recording-only-filename-v1')
  frozen_hash=__import__('hashlib').sha256((json.dumps(policy,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()).hexdigest();inventory['envelope']['payload']['presets'][0]['snapshotHash']=frozen_hash;snapshot['envelope']['payload']['snapshotHash']=frozen_hash
  metadata['envelope']['payload'].update(mode='recordingOnly',localASRPolicy='disabled',locationPolicy='excluded',recordingOnlyFolderPolicyReference='recording-only-folder-v1',recordingOnlyFilenamePolicyReference='recording-only-filename-v1',presetSnapshotHash=frozen_hash)
 return [inventory,snapshot,metadata]
def transfer_flow(recording_only=False):
 out=frozen_prefix(recording_only)+[event('assetManifest',4)]
 f1=event('transferFrontier',5);f1['envelope']['payload'].update(chunkLength=524288,durableOffset=524288,frontierRevision=1,chunkSequence=0)
 f2=event('transferFrontier',6,message_id='bbbbbbb2-1111-4111-8111-111111111111');f2['envelope']['payload'].update(chunkLength=524288,durableOffset=1048576,frontierRevision=2,chunkSequence=1)
 receipt=event('transferReceipt',7);receipt['envelope']['payload'].update(frontierRevision=2)
 out += [f1,f2,receipt,event('phoneIngested',8),event('vaultCommitted',9),event('sourceDeletionAuthorized',10)]
 if recording_only:
  out[-2]['envelope']['payload'].update(verifiedArtifactLength=1048576,verifiedArtifactHash=H[1]);out[-2]['envelope']['messageID']='bbbbbbb1-1111-4111-8111-111111111111'
 return out
flow=transfer_flow()
trace_file('valid-transcript-ingest-commit-delete.json',flow,'sourceDeletionAuthorized',True)
trace_file('valid-recording-only.json',transfer_flow(True),'sourceDeletionAuthorized',True)
# Idempotent duplicate and stale revision/epoch messages remain byte-identical or scoped no-ops.
replay_flow=frozen_prefix()+[event('assetManifest',4),event('transferFrontier',5)]
replay_flow[-1]['envelope']['payload'].update(chunkLength=524288,durableOffset=524288)
replay_flow += [copy.deepcopy(replay_flow[-1])]
replay_flow[-1]['expectedDisposition']='duplicateNoOp'
replay_flow += [event('transferFrontier',4,'staleRevisionNoOp',message_id='aaaaaaa1-1111-4111-8111-111111111111'),event('transferFrontier',99,'staleEpochNoOp',epoch=0,message_id='aaaaaaa2-1111-4111-8111-111111111111')]
trace_file('valid-duplicate-stale-noop.json',replay_flow,'transferFrontier',final_event=replay_flow[-3])
negotiation=[event('capabilityHello',1),event('presetInventory',2),event('presetSnapshot',3),event('reconciliationSummary',4)];negotiation[-1]['envelope']['payload']['recordings'][0].update(lastRevision=3,state='localRecorded');trace_file('valid-negotiation-preset-reconciliation.json',negotiation,'reconciliationSummary')
# Reinstall identity has an independent epoch counter; reconciliation is required before traffic.
reinstall=[event('capabilityHello',1,epoch=100),event('phoneIngested',9,'foreignInstallationRejected',installation=U[8],epoch=1),event('reconciliationSummary',1,installation=U[8],epoch=1),event('phoneIngested',9,'foreignInstallationRejected',installation=U[2],epoch=100)]
reinstall[2]['envelope']['payload']['recordings'][0].update(lastRevision=100,state='localRecorded')
trace_file('valid-reinstall-reconciliation.json',reinstall,'reconciliationSummary',final_event=reinstall[2])
# Typed reconciliation and replay-identity adversarial traces.
x=copy.deepcopy(reinstall);switch=event('reconciliationSummary',1,'accepted',installation=U[2],epoch=101,message_id='ddddddd1-1111-4111-8111-111111111111');x.append(switch);negative_switch=x
x=copy.deepcopy(negotiation);x[-1]['envelope']['payload']['recordings'][0]['recordingID']=U[1];trace_file('invalid-reconciliation-recording-mismatch.json',x,'reconciliationSummary',False)
x=copy.deepcopy(negotiation);x[-1]['envelope']['payload']['recordings'].append(copy.deepcopy(x[-1]['envelope']['payload']['recordings'][0]));trace_file('invalid-reconciliation-duplicate-recording.json',x,'reconciliationSummary',False)
x=copy.deepcopy(negotiation);x[-1]['envelope']['payload']['recordings'][0].update(lastRevision=99,state='vaultCommitted');trace_file('invalid-reconciliation-last-revision.json',x,'reconciliationSummary',False)
x=copy.deepcopy(negotiation);x[-1]['envelope']['payload']['pendingActionCorrelationIDs']=[U[6]];trace_file('invalid-reconciliation-pending-correlation.json',x,'reconciliationSummary',False)
actions=frozen_prefix();actions += [event('reassign',4),event('retry',5)];actions[-1]['envelope']['payload'].update(retryFromRevision=3,actionID=U[6])
trace_file('valid-reassign-retry.json',actions,'retry')
discard_flow=frozen_prefix();discard_action=event('discard',4);discarded=event('discarded',5);discarded['envelope']['payload']['actionReceiptID']=discard_action['envelope']['payload']['actionID'];discard_flow += [discard_action,discarded]
trace_file('valid-explicit-discard.json',discard_flow,'discarded',True)
failure=frozen_prefix()+[event('terminalFailure',4)];trace_file('valid-terminal-failure-retains-media.json',failure,'terminalFailure')
# Isolated typed semantic negatives.
def negative(name,events,state='sourceDeletionAuthorized',deletion=True,final_event=None): trace_file(name,events,state,deletion,final_event)
negative('invalid-retired-installation-switchback.json',negative_switch,'reconciliationSummary',False,final_event=negative_switch[2])
x=copy.deepcopy(flow);x[0]['expectedDisposition']='duplicateNoOp';negative('invalid-disposition.json',x)
x=copy.deepcopy(flow);x[4]['envelope']['payload']['assetID']=U[8];negative('invalid-frontier-asset.json',x)
x=copy.deepcopy(flow);x[7]['envelope']['payload']['assetSHA256']=H[3];negative('invalid-ingest-hash.json',x)
x=copy.deepcopy(flow);x[8]['envelope']['payload']['phoneIngestedCorrelationID']=U[8];negative('invalid-vault-correlation.json',x)
x=copy.deepcopy(flow);x[9]['envelope']['payload']['vaultCommitCorrelationID']=U[8];negative('invalid-delete-correlation.json',x)
x=copy.deepcopy(flow);x.insert(8,x.pop(9));negative('invalid-delete-before-vault.json',x)
x=copy.deepcopy(flow);x.append(event('retry',11));negative('invalid-terminal-followup.json',x)
x=copy.deepcopy(flow);x[7]['envelope']['recordingID']=U[1];negative('invalid-cross-recording-ingest.json',x)
x=copy.deepcopy(flow);x[8]['envelope']['correlationID']=U[8];negative('invalid-cross-correlation-vault.json',x)
x=copy.deepcopy(replay_flow);x[5]['envelope']['payload']['assetSHA256']=H[3];negative('invalid-message-id-collision.json',x,'transferFrontier',False,final_event=x[4])
x=frozen_prefix();x[2]['envelope']['payload']['presetSnapshotHash']=H[3];negative('invalid-metadata-preset.json',x,'recordingMetadata',False)
x=copy.deepcopy(flow);x[5]['envelope']['payload']['frontierRevision']=1;negative('invalid-frontier-revision.json',x)
x=copy.deepcopy(flow);x[5]['envelope']['payload']['chunkSequence']=3;negative('invalid-frontier-progression.json',x)
x=[event('unsupportedVersion',1),event('recordingMetadata',2)];negative('invalid-unsupported-followup.json',x,'recordingMetadata',False)
x=frozen_prefix()+[event('retry',4)];x[-1]['envelope']['payload']['retryFromRevision']=999999;negative('invalid-future-retry.json',x,'retry',False)
x=frozen_prefix();x[-1]['envelope']['payload']['recordingOnlyFolderPolicyReference']='recording-only-folder-v1';negative('invalid-transcript-recording-only-policy.json',x,'recordingMetadata',False)
# Trace envelopes must execute standalone semantics too.
x=transfer_flow(True);x[2]['envelope']['payload']['mode']='transcript';negative('invalid-recording-only-mode-policy.json',x)
x=copy.deepcopy(flow);x[5]['envelope']['payload'].update(chunkLength=600000,durableOffset=1124288);negative('invalid-frontier-exceeds-asset.json',x)
# A same-scope asset replacement after ingest cannot retain old ingest/deletion authority.
x=copy.deepcopy(flow);replacement=event('assetManifest',9,message_id='ccccccc1-1111-4111-8111-111111111111');replacement['envelope']['payload'].update(assetID=U[8],sha256=H[3]);x.insert(8,replacement)
for j in range(9,len(x)): x[j]['envelope']['revision']+=1
negative('invalid-asset-replacement-after-ingest.json',x)
# Later preset messages cannot alter the policy frozen when recording metadata was accepted.
x=frozen_prefix();changed=copy.deepcopy(x[1]);changed['envelope']['revision']=4;changed['envelope']['messageID']='ccccccc2-1111-4111-8111-111111111111';changed['envelope']['payload']['presetRevision']=8;changed['envelope']['payload']['portablePolicy']['destinationCapabilityReference']='synthetic-vault-2';changed_hash=__import__('hashlib').sha256((json.dumps(changed['envelope']['payload']['portablePolicy'],ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()).hexdigest();changed['envelope']['payload']['snapshotHash']=changed_hash
inventory=copy.deepcopy(x[0]);inventory['envelope']['revision']=4;inventory['envelope']['messageID']='ccccccc3-1111-4111-8111-111111111111';inventory['envelope']['payload']['inventoryRevision']=8;inventory['envelope']['payload']['presets'][0].update(revision=8,snapshotHash=changed_hash)
changed['envelope']['revision']=5;reassign_original=event('reassign',6,message_id='ccccccc4-1111-4111-8111-111111111111');reassign_original['envelope']['payload']['targetCapabilityReference']='synthetic-vault-capability';x += [inventory,changed,reassign_original];negative('invalid-frozen-policy-reassignment.json',x,'reassign',False)
# Independently versioned core API records.
core_versions={'artifactPlanVersion':1,'captureMaterializationInputVersion':1,'capturePreparationInputVersion':1,'coreAPIVersion':1,'profileID':'apple-parity-v1','profileVersion':1,'rendererRevision':'swift-legacy-m0','requiredObservationsVersion':1,'toolchainManifestSHA256':H[0]}
core_records={
 'build-info':{'buildConfiguration':'release','coreAPIVersion':1,'coreVersion':'0.1.0-m2-foundation','kind':'buildInfo','sourceRevision':'603e45011a7a7a70363ea790fdc3af5dc54b9f79','supportedOperations':['newNoteTextLink'],'supportedProfileIDs':['apple-parity-v1'],'toolchainManifestSHA256':H[0]},
 'expected-versions':{'kind':'expectedVersions','operation':'newNoteTextLink','versions':core_versions},
 'readiness-ready':{'kind':'readinessResult','mismatchCodes':[],'sessionPermitted':True,'status':'ready'},
 'readiness-incompatible':{'kind':'readinessResult','mismatchCodes':['unsupportedProfile'],'sessionPermitted':False,'status':'incompatible'},
 'expected-artifacts':{'artifacts':[{'artifactID':U[4],'commitSequence':0,'kind':'note','length':25,'mediaType':'text/markdown; charset=utf-8','operationID':U[6],'receiptKind':'noteCommit','resultSHA256':H[3],'streamID':U[3]}],'kind':'expectedArtifactDescriptors','requestID':U[0]},
 'prepared-chunk':{'artifactID':U[4],'byteCount':25,'chunkSHA256':H[3],'eof':True,'kind':'preparedChunkMetadata','sequence':0,'streamID':U[3]},
 'drained-hashes':{'artifacts':[{'artifactID':U[4],'length':25,'resultSHA256':H[3],'streamID':U[3]}],'kind':'drainedArtifactHashes','requestID':U[0]}}
for name,value in core_records.items(): dump('core-api',f'valid-{name}.json',value)
x=copy.deepcopy(core_records['build-info']);x['unexpected']=True;dump('core-api','invalid-unknown-field.json',x)
x=copy.deepcopy(core_records['expected-versions']);x['versions']['profileID']='unknown-profile';dump('core-api','invalid-unsupported-profile.json',x)
x=copy.deepcopy(core_records['readiness-ready']);x['sessionPermitted']=False;dump('core-api','invalid-ready-not-permitted.json',x)
x=copy.deepcopy(core_records['readiness-incompatible']);x['mismatchCodes']=[];dump('core-api','invalid-incompatible-no-mismatch.json',x)
x=copy.deepcopy(core_records['expected-artifacts']);x['artifacts'][0]['commitSequence']=1;dump('core-api','invalid-descriptor-order.json',x)
x=copy.deepcopy(core_records['prepared-chunk']);x['byteCount']=1048577;dump('core-api','invalid-chunk-oversize.json',x)
x=copy.deepcopy(core_records['drained-hashes']);x['artifacts'].append(copy.deepcopy(x['artifacts'][0]));dump('core-api','invalid-duplicate-drained-artifact.json',x)
# Freeze artifact-plan/v1 deterministic UUID and plan-hash derivations.
import uuid,hashlib
IDENTITY_NAMESPACE=uuid.UUID('8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415')
def canonical_bytes(v): return (json.dumps(v,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
def uuid5_bytes(domain,preimage):
 raw=bytearray(hashlib.sha1(IDENTITY_NAMESPACE.bytes+domain.encode('ascii')+b'\0'+canonical_bytes(preimage)).digest()[:16]);raw[6]=(raw[6]&15)|80;raw[8]=(raw[8]&63)|128;return str(uuid.UUID(bytes=bytes(raw)))
def derive_plan(v):
 for a in v['artifacts']:
  a['operationID']=uuid5_bytes('vox.operation.v1',{'commitSequence':a['commitSequence'],'operation':v['operation'],'requestID':v['requestID']})
  a['artifactID']=uuid5_bytes('vox.artifact.v1',{'kind':a['kind'],'logicalPath':a['logicalPath'],'operationID':a['operationID']})
  if a['kind']=='note': a['preparedStreamID']=uuid5_bytes('vox.stream.v1',{'artifactID':a['artifactID'],'resultLength':a['resultLength'],'resultSHA256':a['resultSHA256']})
 v['planHash']='0'*64;v['planHash']=hashlib.sha256(canonical_bytes(v)).hexdigest();return v
plan=derive_plan(plan);dump('artifact-plan','valid-complete.json',plan)
x=copy.deepcopy(plan);x['artifacts'][0]['kind']='note';dump('artifact-plan','invalid-tag-artifact-mismatch.json',x)
x=copy.deepcopy(plan);x['retryMarker']['syntax']='<!-- vox-operation:{lowercase-uuid} -->';dump('artifact-plan','invalid-marker-syntax.json',x)
x=copy.deepcopy(plan);x['artifacts'][1]['commitSequence']=0;dump('artifact-plan','invalid-commit-order.json',x)
x=copy.deepcopy(plan);x['preparedByteDelivery']['finalJSONDuplicatesBytes']=True;dump('artifact-plan','invalid-final-json-byte-duplication.json',x)

# Exact M3 text/link input shared by Kotlin enqueue and the existing Rust core.
m3_preset={
 'destinationPolicy':{'capabilityClass':'userVault','capabilityReference':'synthetic-vault-capability','expectedCaseSensitivity':'sensitive'},
 'id':'33333333-3333-4333-8333-333333333333',
 'metadataPolicy':{'finalNewline':True,'frontmatterMode':'none','lineEnding':'lf','orderedFields':[],'templatePolicy':'none'},
 'retryMarkerPolicy':'none','revision':1,
 'routePolicy':{'attachmentFolder':[],'collisionPolicy':'deterministicSuffix','extensionPolicy':'markdownDotMd','logicalFolder':['Inbox'],'noteNameTemplate':'capture-{id}.md'},
 'snapshotHash':'0'*64,'templateFreezePoint':'firstPreparation'}
m3_preset['snapshotHash']=hashlib.sha256(canonical_bytes(m3_preset)).hexdigest()
m3={'calendar':'gregorian','captureSource':'app','contractVersion':1,'createdAtEpochMilliseconds':1700000000000,
 'invocation':{'locationOutcome':'notRequested','originRecordingID':None,'sequence':1},'locale':'en-US','operation':'newNote',
 'payloads':[{'id':U[1],'kind':'text','text':'Synthetic capture text.'},{'id':U[3],'kind':'link','label':'Synthetic link','url':'https://example.invalid/synthetic'}],
 'pins':{'coreVersion':'0.1.0-alpha.1','modelProfileID':None,'modelRevision':None,'profileID':'apple-parity-v1','profileVersion':1,'rendererRevision':'swift-legacy-m0'},
 'preset':m3_preset,'requestID':U[0],'timezone':'America/Los_Angeles'}
dump('capture-preparation-input','valid-android-m3-text-link.json',m3)

# Android package envelopes are all derived here from the exact governed request/assets bytes.
assets={'assetCount':0,'assets':[],'requestID':U[0],'schemaVersion':1}
request_bytes=canonical_bytes(m3); asset_bytes=canonical_bytes(assets)
def je(revision,from_state,state,code,receipt=None,resume=None):
 return {'code':code,'fromState':from_state,'occurredAtEpochMillis':1700000000000+revision,'receiptID':receipt,'resumeState':resume,'revision':revision,'state':state}
def journal(events):
 return {'assetManifestByteCount':len(asset_bytes),'assetManifestSHA256':hashlib.sha256(asset_bytes).hexdigest(),'assetManifestVersion':1,'events':events,'journalVersion':1,'packageVersion':1,'requestByteCount':len(request_bytes),'requestID':U[0],'requestSHA256':hashlib.sha256(request_bytes).hexdigest(),'requestContractVersion':1}
valid_events=[je(0,None,'queued','enqueued'),je(1,'queued','preparing','preparationStarted'),je(2,'preparing','materialized','materialized'),je(3,'materialized','committing','commitStarted'),je(4,'committing','unknownOutcome','commitAmbiguous'),je(5,'unknownOutcome','completed','verifiedCommitted',U[6])]
dump('android-capture-package','valid-assets.json',assets)
dump('android-capture-package','valid-queued-journal.json',journal(valid_events[:1]))
dump('android-capture-package','valid-journal.json',journal(valid_events))
x=copy.deepcopy(assets);x['schemaVersion']=2;dump('android-capture-package','invalid-version.json',x)
dump('android-capture-package','invalid-transition.json',journal([valid_events[0],je(1,'queued','completed','verifiedCommitted',U[6])]))
dump('android-capture-package','invalid-terminal-successor.json',journal(valid_events+[je(6,'completed','discarded','userDiscarded')]))
dump('android-capture-package','invalid-materialized-self-transition.json',journal(valid_events[:3]+[je(3,'materialized','materialized','materialized')]))
