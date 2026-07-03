// Golden vectors for the secure-session crypto, generated from netmd-js's
// own retailmac and the CryptoJS primitives it uses.
//
// Run from the netmd-js checkout:
//   npx ts-node -T ../netmd/tools/gen_crypto_vectors.ts > ../netmd/test/fixtures/crypto_vectors.json

import * as path from 'path';
import { retailmac } from '../../netmd-js/src/netmd-interface';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const cryptoModule = require(path.join(
    __dirname,
    '../../netmd-js/node_modules/@originjs/crypto-js-wasm'
));
const Crypto = cryptoModule.default ?? cryptoModule;

function mulberry32(a: number) {
    return function() {
        a |= 0;
        a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
const rand = mulberry32(0xc0ffee);
const randBytes = (n: number) =>
    new Uint8Array(new Array(n).fill(0).map(() => Math.floor(rand() * 256)));

const hex = (u8: Uint8Array) =>
    Array.from(u8)
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');

function wordArrayToByteArray(wordArray: any, length: number = wordArray.sigBytes) {
    const res = new Uint8Array(length);
    let offset = 0;
    let i = 0;
    let left = length;
    while (left > 0) {
        const word = wordArray.words[i];
        const bytes = [(word >>> 24) & 0xff, (word >>> 16) & 0xff, (word >>> 8) & 0xff, word & 0xff];
        for (const b of bytes.slice(0, Math.min(4, left))) {
            res[offset++] = b;
        }
        left -= Math.min(4, left);
        i++;
    }
    return res;
}

async function main() {
    await Crypto.algo.DES.loadWasm();
    await Crypto.algo.TripleDES.loadWasm();

    // retailmac vectors: 16-byte key (EKB root key shape), 16-byte value
    // (host nonce + device nonce)
    const retailmacVectors = [];
    for (let i = 0; i < 8; i++) {
        const key = randBytes(16);
        const value = randBytes(16);
        retailmacVectors.push({
            key: hex(key),
            value: hex(value),
            mac: retailmac(key, value),
        });
    }

    // DES-ECB decrypt: packet key derivation from a random key and the KEK
    const ecbVectors = [];
    for (let i = 0; i < 4; i++) {
        const kek = randBytes(8);
        const rawKey = randBytes(8);
        const keyDec = Crypto.DES.decrypt(
            { ciphertext: Crypto.lib.WordArray.create(rawKey) },
            Crypto.lib.WordArray.create(kek),
            { mode: Crypto.mode.ECB, padding: Crypto.pad.Pkcs7 }
        );
        keyDec.sigBytes = 8;
        ecbVectors.push({ kek: hex(kek), raw_key: hex(rawKey), packet_key: hex(wordArrayToByteArray(keyDec)) });
    }

    // DES-CBC chained chunk encryption, as in the packet iterator
    const cbcVectors = [];
    for (const chunkSizes of [[16], [24, 16]]) {
        const key = randBytes(8);
        let iv = new Uint8Array(8);
        const chunks = [];
        for (const size of chunkSizes) {
            const data = randBytes(size);
            const encrypted = Crypto.DES.encrypt(
                Crypto.lib.WordArray.create(data),
                Crypto.lib.WordArray.create(key),
                { mode: Crypto.mode.CBC, iv: Crypto.lib.WordArray.create(iv) }
            );
            let out = wordArrayToByteArray(encrypted.ciphertext);
            out = out.subarray(0, size);
            chunks.push({ iv: hex(iv), data: hex(data), encrypted: hex(out) });
            iv = out.subarray(out.length - 8);
        }
        cbcVectors.push({ key: hex(key), chunks });
    }

    // setupDownload message encryption: DES-CBC, zero IV, no padding
    const sessionKey = randBytes(8);
    const contentId = randBytes(20);
    const kek = randBytes(8);
    const message = new Uint8Array([1, 1, 1, 1, ...contentId, ...kek]);
    const setupEncrypted = Crypto.DES.encrypt(
        Crypto.lib.WordArray.create(message),
        Crypto.lib.WordArray.create(sessionKey),
        {
            mode: Crypto.mode.CBC,
            padding: Crypto.pad.NoPadding,
            iv: Crypto.enc.Hex.parse('0000000000000000'),
        }
    );

    // commitTrack authentication: DES-ECB of zeros, no padding
    const commitEncrypted = Crypto.DES.encrypt(
        Crypto.enc.Hex.parse('0000000000000000'),
        Crypto.lib.WordArray.create(sessionKey),
        { mode: Crypto.mode.ECB, padding: Crypto.pad.NoPadding }
    );

    process.stdout.write(
        JSON.stringify(
            {
                retailmac: retailmacVectors,
                ecb_decrypt: ecbVectors,
                cbc_chain: cbcVectors,
                setup_download: {
                    session_key: hex(sessionKey),
                    content_id: hex(contentId),
                    kek: hex(kek),
                    encrypted: hex(wordArrayToByteArray(setupEncrypted.ciphertext)),
                },
                commit_track: {
                    session_key: hex(sessionKey),
                    auth: hex(wordArrayToByteArray(commitEncrypted.ciphertext)),
                },
            },
            null,
            1
        )
    );
}

main();
