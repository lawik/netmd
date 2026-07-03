// Golden vector generator for the NetMD query DSL.
//
// Runs netmd-js's own formatQuery/scanQuery/BCD implementations (the reference
// this library ports) over every format string harvested from its protocol
// layer, with deterministic pseudo-random arguments, and emits JSON vectors
// used by the ExUnit suite to verify byte-for-byte equivalence.
//
// Run from the netmd-js checkout (sibling of this repo):
//   npx ts-node -T ../netmd/tools/gen_query_vectors.ts > ../netmd/test/fixtures/query_vectors.json

import * as fs from 'fs';
import * as path from 'path';
import { formatQuery, scanQuery, BCD2int, int2BCD } from '../../netmd-js/src/query-utils';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const JSBI = require(path.join(__dirname, '../../netmd-js/node_modules/jsbi'));

// Deterministic PRNG (mulberry32) so vectors are stable across runs.
function mulberry32(a: number) {
    return function() {
        a |= 0;
        a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
const rand = mulberry32(0x5eed);
const randInt = (maxExclusive: number) => Math.floor(rand() * maxExclusive);
const randBytes = (n: number) => new Uint8Array(new Array(n).fill(0).map(() => randInt(256)));

const hex = (u8: Uint8Array | ArrayBuffer) =>
    Array.from(u8 instanceof ArrayBuffer ? new Uint8Array(u8) : u8)
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');

type Token = { kind: 'const'; byte: number } | { kind: 'fmt'; char: string; little: boolean };

function tokenize(format: string): Token[] {
    const tokens: Token[] = [];
    let half: string | null = null;
    let escaped = false;
    let little = false;
    for (const char of format) {
        if (escaped) {
            if (char === '<') {
                little = true;
                continue;
            }
            if (char === '>') {
                continue;
            }
            tokens.push({ kind: 'fmt', char, little });
            little = false;
            escaped = false;
            continue;
        }
        if (char === '%') {
            escaped = true;
            continue;
        }
        if (char === ' ') continue;
        if (half === null) {
            half = char;
        } else {
            tokens.push({ kind: 'const', byte: Number.parseInt(half + char, 16) });
            half = null;
        }
    }
    return tokens;
}

// ---- formatQuery vectors ----

type JsonArg = { t: 'int'; v: string } | { t: 'bytes'; v: string };

function makeFormatArgs(tokens: Token[]): { args: unknown[]; jsonArgs: JsonArg[] } {
    const args: unknown[] = [];
    const jsonArgs: JsonArg[] = [];
    for (const tok of tokens) {
        if (tok.kind !== 'fmt') continue;
        switch (tok.char) {
            case 'b': {
                const v = randInt(256);
                args.push(v);
                jsonArgs.push({ t: 'int', v: String(v) });
                break;
            }
            case 'w': {
                const v = randInt(0x10000);
                args.push(v);
                jsonArgs.push({ t: 'int', v: String(v) });
                break;
            }
            case 'd': {
                const v = randInt(0x100000000);
                args.push(v);
                jsonArgs.push({ t: 'int', v: String(v) });
                break;
            }
            case 'q': {
                const v = JSBI.BigInt('0x' + hex(randBytes(8)));
                args.push(v);
                jsonArgs.push({ t: 'int', v: v.toString() });
                break;
            }
            case 'x':
            case 's': {
                const v = randBytes(randInt(17));
                args.push(v);
                jsonArgs.push({ t: 'bytes', v: hex(v) });
                break;
            }
            case 'z': {
                const v = randBytes(randInt(17));
                args.push(v);
                jsonArgs.push({ t: 'bytes', v: hex(v) });
                break;
            }
            case '*': {
                const v = randBytes(randInt(9));
                args.push(v);
                jsonArgs.push({ t: 'bytes', v: hex(v) });
                break;
            }
            case 'B':
            case 'W': {
                // formatQuery calls int2BCD with default length 1, so > 99 throws.
                const v = randInt(100);
                args.push(v);
                jsonArgs.push({ t: 'int', v: String(v) });
                break;
            }
            default:
                throw new Error(`format arg for %${tok.char} not supported`);
        }
    }
    return { args, jsonArgs };
}

// ---- scanQuery vectors ----

function makeScanInput(tokens: Token[]): Uint8Array {
    const out: number[] = [];
    for (const tok of tokens) {
        if (tok.kind === 'const') {
            out.push(tok.byte);
            continue;
        }
        switch (tok.char) {
            case '?':
                out.push(randInt(256));
                break;
            case 'b':
                out.push(...randBytes(1));
                break;
            case 'w':
                out.push(...randBytes(2));
                break;
            case 'd':
                out.push(...randBytes(4));
                break;
            case 'q':
                out.push(...randBytes(8));
                break;
            case 'x':
            case 's': {
                const n = randInt(17);
                out.push(n >> 8, n & 0xff, ...randBytes(n));
                break;
            }
            case 'z': {
                const n = randInt(17);
                out.push(n, ...randBytes(n));
                break;
            }
            case '*':
            case '#':
                out.push(...randBytes(randInt(9)));
                break;
            case 'B': {
                out.push(int2BCD(randInt(100)));
                break;
            }
            case 'W': {
                const bcd = int2BCD(randInt(10000), 2);
                out.push(bcd >> 8, bcd & 0xff);
                break;
            }
            default:
                throw new Error(`scan input for %${tok.char} not supported`);
        }
    }
    return new Uint8Array(out);
}

function serializeResults(results: unknown[]): JsonArg[] {
    return results.map(r => {
        if (r instanceof Uint8Array) return { t: 'bytes', v: hex(r) } as JsonArg;
        return { t: 'int', v: (r as { toString(): string }).toString() } as JsonArg;
    });
}

// ---- format string harvesting ----

function harvestFormats(): { formatStrings: string[]; scanStrings: string[] } {
    const sources = [
        '../../netmd-js/src/netmd-interface.ts',
        '../../netmd-js/src/factory/netmd-factory-interface.ts',
        '../../netmd-js/src/factory/netmd-factory-commands.ts',
    ].map(p => fs.readFileSync(path.join(__dirname, p), 'utf-8'));

    const formatStrings = new Set<string>();
    const scanStrings = new Set<string>();
    for (const src of sources) {
        for (const m of src.matchAll(/formatQuery\(\s*'([^']+)'/g)) {
            formatStrings.add(m[1]);
        }
        for (const m of src.matchAll(/scanQuery\(\s*[^,]+,\s*'([^']+)'\s*\)/g)) {
            scanStrings.add(m[1]);
        }
    }

    // Template literals the regex cannot see, expanded by hand.
    const descriptors = ['10 1801', '10 1802', '10 1803', '10 1804', '10 1001', '10 1000', '00', '80 00'];
    const actions = ['01', '03', '00'];
    for (const d of descriptors) {
        for (const a of actions) {
            formatStrings.add(`1808 ${d} ${a} 00`);
        }
    }
    // getPosition reply format (concatenated literal in the source).
    scanStrings.add(
        '1809 8001 0430 %?%? %?%? %?%? %?%? %?%? %?%? %?%? %? %?00 00%?0000 000b 0002 0007 00 %w %B %B %B %B'
    );
    return { formatStrings: [...formatStrings].sort(), scanStrings: [...scanStrings].sort() };
}

// ---- main ----

const { formatStrings, scanStrings } = harvestFormats();
const VARIANTS = 3;

const formatVectors = [];
for (const f of formatStrings) {
    const tokens = tokenize(f);
    for (let i = 0; i < VARIANTS; i++) {
        const { args, jsonArgs } = makeFormatArgs(tokens);
        const result = formatQuery(f, ...args);
        formatVectors.push({ format: f, args: jsonArgs, result: hex(result) });
    }
}

const scanVectors = [];
for (const f of scanStrings) {
    const tokens = tokenize(f);
    for (let i = 0; i < VARIANTS; i++) {
        const input = makeScanInput(tokens);
        const results = scanQuery(input, f);
        scanVectors.push({ format: f, input: hex(input), results: serializeResults(results) });
    }
}

const bcdVectors = [];
const bcdCases: [number, number][] = [
    [0, 1], [1, 1], [9, 1], [10, 1], [24, 1], [55, 1], [99, 1],
    [0, 2], [100, 2], [2402, 2], [9999, 2],
    [123456, 3], [999999, 3],
    [1234, 4], [12345678, 4], [99999999, 4],
];
for (const [value, length] of bcdCases) {
    const bcd = int2BCD(value, length) >>> 0; // JS bitwise ops are signed 32-bit
    bcdVectors.push({ value, length, bcd, roundtrip: BCD2int(bcd) });
}

process.stdout.write(
    JSON.stringify({ format: formatVectors, scan: scanVectors, bcd: bcdVectors }, null, 1)
);
