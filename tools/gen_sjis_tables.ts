// Generate Shift-JIS mapping tables from jconv, the codec netmd-js uses.
//
// Writes two TSV files (hex codepoint <tab> hex bytes):
//   priv/sjis/encode.tsv - unicode codepoint -> SJIS bytes
//   priv/sjis/decode.tsv - SJIS bytes -> unicode codepoint
//
// Run from the netmd-js checkout:
//   npx ts-node -T ../netmd/tools/gen_sjis_tables.ts

import * as fs from 'fs';
import * as path from 'path';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const jconv = require(path.join(__dirname, '../../netmd-js/node_modules/jconv'));

const outDir = path.join(__dirname, '../priv/sjis');
fs.mkdirSync(outDir, { recursive: true });

const encodeLines: string[] = [];
for (let cp = 0x80; cp <= 0xffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue; // surrogates
    const char = String.fromCharCode(cp);
    let encoded: Buffer;
    try {
        encoded = jconv.encode(char, 'SJIS');
    } catch (err) {
        continue;
    }
    if (encoded.length === 0 || encoded.length > 2) continue;
    // jconv writes KATAKANA MIDDLE DOT (0x8145) for unmappable characters
    if (encoded.length === 2 && encoded[0] === 0x81 && encoded[1] === 0x45 && cp !== 0x30fb) {
        continue;
    }
    encodeLines.push(`${cp.toString(16)}\t${encoded.toString('hex')}`);
}
fs.writeFileSync(path.join(outDir, 'encode.tsv'), encodeLines.join('\n') + '\n');

const decodeLines: string[] = [];
function tryDecode(bytes: number[]) {
    let decoded: string;
    try {
        decoded = jconv.decode(Buffer.from(bytes), 'SJIS');
    } catch (err) {
        return;
    }
    if (decoded.length !== 1) return;
    const cp = decoded.charCodeAt(0);
    if (cp === 0xfffd) return;
    // jconv decodes invalid sequences to KATAKANA MIDDLE DOT (U+30FB)
    if (cp === 0x30fb && !(bytes.length === 2 && bytes[0] === 0x81 && bytes[1] === 0x45)) return;
    decodeLines.push(`${bytes.map(b => b.toString(16).padStart(2, '0')).join('')}\t${cp.toString(16)}`);
}

for (let b = 0x80; b <= 0xff; b++) {
    tryDecode([b]);
}
for (let lead = 0x81; lead <= 0xfc; lead++) {
    if (lead > 0x9f && lead < 0xe0) continue;
    for (let trail = 0x40; trail <= 0xfc; trail++) {
        if (trail === 0x7f) continue;
        tryDecode([lead, trail]);
    }
}
fs.writeFileSync(path.join(outDir, 'decode.tsv'), decodeLines.join('\n') + '\n');

process.stdout.write(`encode entries: ${encodeLines.length}\ndecode entries: ${decodeLines.length}\n`);
