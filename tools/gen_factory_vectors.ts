// Golden vectors for the factory-mode pure functions, generated from
// netmd-js itself.
//
// Run from the netmd-js checkout:
//   npx ts-node -T ../netmd/tools/gen_factory_vectors.ts > ../netmd/test/fixtures/factory_vectors.json

import { calculateEEPROMChecksum } from '../../netmd-js/src/factory/netmd-factory-interface';
import { getDescriptiveDeviceCode } from '../../netmd-js/src/factory/netmd-factory-commands';
import * as path from 'path';
import {
    encryptDataForFactoryTransfer,
    decryptDataFromFactoryTransfer,
} from '../../netmd-js/src/utils';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const cryptoModule = require(path.join(__dirname, '../../netmd-js/node_modules/@originjs/crypto-js-wasm'));
const Crypto = cryptoModule.default ?? cryptoModule;

// calculateChecksum is not exported; re-implement the 8-bit variant here
// only to cross-check our port. It is validated indirectly through the
// write() query vectors too, but an explicit vector is clearer.
function calculateChecksum(data: Uint8Array, as16Bit: boolean, seed = 0) {
    let crc = seed;
    let newData: Uint8Array | Uint16Array = data;
    if (as16Bit) {
        newData = new Uint16Array(data.length / 2);
        for (let i = 0; i < newData.length; i++) {
            newData[i] = (data[2 * i + 1] << 8) | data[2 * i];
        }
    }
    let temp = newData.length;
    newData.forEach((e: any) => {
        temp = (temp & 0xffff0000) | e;
        crc ^= temp;
        for (let i = 0; i < 16; i++) {
            let ts = crc & 0x8000;
            crc <<= 1;
            if (ts) crc ^= 0x1021;
        }
    });
    return (crc & 0xffff) >>> 0;
}

function mulberry32(a: number) {
    return function() {
        a |= 0;
        a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
const rand = mulberry32(0xfac7);
const randBytes = (n: number) => new Uint8Array(new Array(n).fill(0).map(() => Math.floor(rand() * 256)));
const hex = (u8: Uint8Array) => Array.from(u8).map(b => b.toString(16).padStart(2, '0')).join('');

async function main() {
    await Crypto.algo.DES.loadWasm();

const checksum8 = [0, 4, 8, 16].map(n => {
    const data = randBytes(n);
    return { data: hex(data), checksum: calculateChecksum(data, false) };
});

const checksum8Seed = [8, 16].map(n => {
    const data = randBytes(n);
    return { data: hex(data), seed: 0xa596, checksum: calculateChecksum(data, false, 0xa596) };
});

const eepromChecksum = [8, 32, 128].map(n => {
    const data = randBytes(n);
    return {
        data: hex(data),
        himd_checksum: calculateEEPROMChecksum(data, true),
        netmd_checksum: calculateEEPROMChecksum(data, false),
    };
});

const transferCrypto = [8, 16, 32].map(n => {
    const data = randBytes(n);
    return {
        plaintext: hex(data),
        encrypted: hex(encryptDataForFactoryTransfer(data)),
        // decrypt is the inverse of the raw ECB, so feed the encrypted bytes back
        roundtrip: hex(decryptDataFromFactoryTransfer(encryptDataForFactoryTransfer(data))),
    };
});

const deviceCodes = await Promise.all(
    [
        { chipType: 0x20, version: 21, subversion: 0x00 },
        { chipType: 0x21, version: 25, subversion: 0x12 },
        { chipType: 0x22, version: 10, subversion: 0xff },
        { chipType: 0x24, version: 30, subversion: 0x0a },
        { chipType: 0x25, version: 12, subversion: 0x03 },
        { chipType: 0x99, version: 11, subversion: 0x01 },
    ].map(async input => ({ ...input, code: await getDescriptiveDeviceCode(input) }))
);

    process.stdout.write(
        JSON.stringify(
            { checksum8, checksum8_seed: checksum8Seed, eeprom_checksum: eepromChecksum, transfer_crypto: transferCrypto, device_codes: deviceCodes },
            null,
            1
        )
    );
}

main();
