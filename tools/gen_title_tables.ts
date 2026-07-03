// Extract the title sanitization tables from netmd-js utils.ts and the
// diacritics package into priv/titles_tables.json, avoiding error-prone
// manual transcription.
//
// Run from the netmd-js checkout:
//   npx ts-node -T ../netmd/tools/gen_title_tables.ts

import * as fs from 'fs';
import * as path from 'path';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const diacritics = require(path.join(__dirname, '../../netmd-js/node_modules/diacritics'));

const source = fs.readFileSync(path.join(__dirname, '../../netmd-js/src/utils.ts'), 'utf-8');

function extractObject(name: string, occurrence = 0): { [key: string]: unknown } {
    const re = new RegExp(`const ${name}[^=]*= ({.*?});`, 'gs');
    const matches = [...source.matchAll(re)];
    if (matches.length <= occurrence) throw new Error(`cannot find ${name} #${occurrence}`);
    // eslint-disable-next-line no-eval
    return eval('(' + matches[occurrence][1] + ')');
}

function extractString(name: string): string {
    const re = new RegExp(`const ${name} = '(.*?)'`, 's');
    const m = source.match(re);
    if (!m) throw new Error(`cannot find ${name}`);
    return m[1];
}

const multiByteChars = extractObject('multiByteChars');
// occurrence 0 of `const mappings` is halfWidthToFullWidthRange's table,
// occurrence 1 is sanitizeHalfWidthTitle's fullwidth -> halfwidth map
const rangeMappings = extractObject('mappings', 0);
const halfMappings = extractObject('mappings', 1);
const mappingsJP = extractObject('mappingsJP');
const mappingsRU = extractObject('mappingsRU');
const mappingsDE = extractObject('mappingsDE');
const handakutenPossible = extractString('handakutenPossible');
const dakutenPossible = extractString('dakutenPossible') + handakutenPossible;

const diacriticsMap: { [key: string]: string } = {};
for (const { base, chars } of diacritics.replacementList) {
    for (const char of [...chars]) {
        diacriticsMap[char] = base;
    }
}

const out = {
    multibyte: Object.keys(multiByteChars),
    range: rangeMappings,
    half: halfMappings,
    jp: mappingsJP,
    ru: mappingsRU,
    de: mappingsDE,
    handakuten_possible: handakutenPossible,
    dakuten_possible: dakutenPossible,
    diacritics: diacriticsMap,
};

fs.writeFileSync(path.join(__dirname, '../priv/titles_tables.json'), JSON.stringify(out, null, 1));
process.stdout.write(
    `multibyte: ${out.multibyte.length}, range: ${Object.keys(rangeMappings).length}, ` +
        `half: ${Object.keys(halfMappings).length}, ` +
        `jp: ${Object.keys(mappingsJP).length}, ru: ${Object.keys(mappingsRU).length}, ` +
        `de: ${Object.keys(mappingsDE).length}, diacritics: ${Object.keys(diacriticsMap).length}\n`
);
