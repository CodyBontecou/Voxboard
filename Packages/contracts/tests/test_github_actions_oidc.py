from __future__ import annotations

import base64
import hashlib
import json
import os
import time
import unittest
from pathlib import Path
from unittest import mock

import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import github_actions_oidc as oidc

ROOT=Path(__file__).resolve().parents[3]

N=int('b315175ba743eca7f2d76c2a39b28a470f15c3fa72b950d2a6db1b72a6915702b5ed1513166984e17aa9c6ffdb859855338ad718741351b0e140d8ce9657123223e0f26ab2eb48d32bd8e10928089756df53731389b829a55154676e661f7eef928676266f6ee377f0231ddabfaf2e8cc04a8c619073e26e773df6c2381fdde9b95ed078e89229c57f50b6fd0e7e0c2e2d50f224181ae21b6014c6fb893f85e316ba965b96f21809987efea991165bd5742b7f1aa9b9ddb8c0fa19ad42bef4a6a85b0fcacfbbbe9002d6982815499406357d4928356e47f3ba1f3447ab17accd6990bb9859543a030ea26cc986be15b6534bbd3a6256e3ba499e99e41e7aed0f',16)
D=int('0ebbdd801cf2e9b5a7b531a107be38c23feb7a84508c0eaa463020c1fe12572651f17f9a626dac11211676d8f626b7b1cadbd176a19635526835fda0819e085137c27a2f6d290e84d146b6bd1a1e1ad57aea52bd78c73e25ebdb15e76f5f88020dfc221c676ea82866097d9b51ca07fa6c97b595115d7773bf3bc9e190dc8e55591de390a4eaccb8d2510519b9f35e87c957878f697dde8423d8155446ab37bb8a9feaaa74251b3f822f169f820dd665be8e755d28cc39b8f4121b9a9934a053b36f5f8b01ef57459c6a32904e3546c57dfce9a41452bc3cf5c219ec31ccc7441a785f2dd3d0fc0bc08da136152a1184bec5888baf184af36a73779cdeacfb81',16)
E=65537

def b64(data:bytes)->str: return base64.urlsafe_b64encode(data).decode().rstrip('=')
def integer(value:int)->str: return b64(value.to_bytes((value.bit_length()+7)//8,'big'))

def token(claims):
 header=b64(json.dumps({'alg':'RS256','kid':'test-key','typ':'JWT'},sort_keys=True,separators=(',',':')).encode()); payload=b64(json.dumps(claims,sort_keys=True,separators=(',',':')).encode()); signing=f'{header}.{payload}'.encode(); digest_info=bytes.fromhex('3031300d060960864801650304020105000420')+hashlib.sha256(signing).digest(); width=(N.bit_length()+7)//8; encoded=b'\x00\x01'+b'\xff'*(width-len(digest_info)-3)+b'\x00'+digest_info; signature=pow(int.from_bytes(encoded,'big'),D,N).to_bytes(width,'big'); return f'{header}.{payload}.{b64(signature)}'

class OIDCTests(unittest.TestCase):
 def setUp(self):
  self.now=int(time.time()); self.expected={'sourceRevision':'a'*40,'workflowRevision':'b'*40,'workflowReference':'CodyBontecou/vox.md/.github/workflows/core-rust-ci.yml@refs/heads/main','runID':'123','runAttempt':2,'ref':'refs/heads/main','eventName':'push'}
  self.claims={'iss':oidc.ISSUER,'aud':oidc.AUDIENCE,'sub':oidc.SUBJECT_REPOSITORY_PREFIX+':ref:refs/heads/main','jti':'00000000-0000-4000-8000-000000000001','repository':oidc.REPOSITORY,'repository_id':oidc.REPOSITORY_ID,'repository_owner':oidc.OWNER,'repository_owner_id':oidc.OWNER_ID,'repository_visibility':oidc.VISIBILITY,'sha':self.expected['sourceRevision'],'workflow_sha':self.expected['workflowRevision'],'workflow_ref':self.expected['workflowReference'],'run_id':'123','run_attempt':'2','ref':self.expected['ref'],'event_name':'push','runner_environment':'github-hosted','iat':self.now-1,'nbf':self.now-1,'exp':self.now+300}
  self.jwks={'keys':[{'kty':'RSA','alg':'RS256','use':'sig','kid':'test-key','n':integer(N),'e':integer(E)}]}
 def test_valid_rs256_token_and_exact_claims_pass(self): oidc.validate_token(token(self.claims),self.jwks,self.expected,self.now)
 def test_repository_ref_source_workflow_issuer_and_audience_claim_mutations_fail(self):
  for claim,value in [('repository','attacker/fork'),('repository_id','1'),('sub','repo:attacker@1/fork@2:ref:refs/heads/main'),('ref','refs/heads/attacker'),('sha','0'*40),('workflow_sha','0'*40),('workflow_ref','CodyBontecou/vox.md/.github/workflows/other.yml@refs/heads/main'),('iss','https://attacker.invalid'),('aud','https://attacker.invalid')]:
   mutated=dict(self.claims); mutated[claim]=value
   with self.subTest(claim=claim),self.assertRaisesRegex(oidc.OIDCError,claim+' claim mismatch'): oidc.validate_token(token(mutated),self.jwks,self.expected,self.now)
 def test_signature_time_header_and_bounds_fail_closed(self):
  good=token(self.claims); head,payload,signature=good.split('.'); raw=bytearray(base64.urlsafe_b64decode(signature+'='*(-len(signature)%4))); raw[0]^=1; bad=f'{head}.{payload}.{b64(bytes(raw))}'; self.assertRaisesRegex(oidc.OIDCError,'signature verification failed',oidc.validate_token,bad,self.jwks,self.expected,self.now)
  expired=dict(self.claims); expired['exp']=self.now; self.assertRaisesRegex(oidc.OIDCError,'time claims',oidc.validate_token,token(expired),self.jwks,self.expected,self.now)
  missing_jti=dict(self.claims); del missing_jti['jti']; self.assertRaisesRegex(oidc.OIDCError,'jti claim',oidc.validate_token,token(missing_jti),self.jwks,self.expected,self.now)
  self.assertRaisesRegex(oidc.OIDCError,'oversized',oidc.validate_token,'x'*oidc.MAX_TOKEN_BYTES,self.jwks,self.expected,self.now)
 def test_token_request_host_is_bounded_to_github_actions_domain(self):
  for host in ('pipelines.actions.githubusercontent.com','vstoken.actions.githubusercontent.com','pipelinesghubeus25.actions.githubusercontent.com'):
   self.assertTrue(oidc._is_token_endpoint_host(host),host)
  for host in (None,'actions.githubusercontent.com','attacker.invalid','vstoken.actions.githubusercontent.com.attacker.invalid','-bad.actions.githubusercontent.com','bad..actions.githubusercontent.com'):
   self.assertFalse(oidc._is_token_endpoint_host(host),host)
 def test_token_request_url_is_pinned_before_network_access(self):
  environment={'GITHUB_REF':'refs/heads/main','GITHUB_EVENT_NAME':'push','GITHUB_WORKFLOW_REF':self.expected['workflowReference'],'GITHUB_WORKFLOW_SHA':self.expected['workflowRevision'],'ACTIONS_ID_TOKEN_REQUEST_URL':'https://attacker.invalid/token','ACTIONS_ID_TOKEN_REQUEST_TOKEN':'x'*32}
  qualification={'runID':'123','runAttempt':2}
  with mock.patch.dict(os.environ,environment,clear=True),self.assertRaisesRegex(oidc.OIDCError,'pinned GitHub Actions HTTPS endpoint'):
   oidc.authenticate(ROOT,qualification,self.expected['sourceRevision'])

if __name__=='__main__': unittest.main()
