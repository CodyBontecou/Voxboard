// Generate App Store Connect JWT using Node.js built-in crypto
import crypto from 'crypto';
import fs from 'fs';

const keyId = process.argv[2];
const issuerId = process.argv[3];
const keyPath = process.argv[4];

const privateKey = fs.readFileSync(keyPath, 'utf8');

const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
const now = Math.floor(Date.now() / 1000);
const payload = { iss: issuerId, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' };

const encode = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
const unsigned = `${encode(header)}.${encode(payload)}`;

// Sign with ES256 — need to use IEEE P1363 format (raw r||s), not DER
const sign = crypto.createSign('SHA256');
sign.update(unsigned);
const derSig = sign.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' });
const signature = derSig.toString('base64url');

console.log(`${unsigned}.${signature}`);
