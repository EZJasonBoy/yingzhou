import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const manifestPath = process.argv[2];
const payload = readFileSync(manifestPath);
const manifest = JSON.parse(payload);
const privateKey = createPrivateKey(process.env.UPDATE_MANIFEST_ED25519);
const publicKey = createPublicKey(privateKey);
const pinned = readFileSync(new URL('../client/assets/update-ed25519.hex', import.meta.url), 'utf8').trim();
if (publicKey.asymmetricKeyType !== 'ed25519' || Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('hex') !== pinned) {
  throw new Error('The signing key does not match the public key bundled in the client');
}
const signature = sign(null, payload, privateKey);
if (!verify(null, payload, publicKey, signature)) throw new Error('Invalid update manifest signature');
writeFileSync(manifestPath, JSON.stringify({ ...manifest, signed: payload.toString('base64'), signature: signature.toString('base64') }) + '\n');
