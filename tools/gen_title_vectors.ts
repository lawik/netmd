// Golden vectors for title handling, generated from the netmd-js utils.
//
// Run from the netmd-js checkout:
//   npx ts-node -T ../netmd/tools/gen_title_vectors.ts > ../netmd/test/fixtures/title_vectors.json

import {
    encodeToSJIS,
    decodeFromSJIS,
    getLengthAfterEncodingToSJIS,
    getHalfWidthTitleLength,
    sanitizeHalfWidthTitle,
    sanitizeFullWidthTitle,
    aggressiveSanitizeTitle,
    halfWidthToFullWidthRange,
} from '../../netmd-js/src/utils';

const titles = [
    '',
    'Hello World',
    'hello/slash;semi-dash',
    'UPPER lower 0123456789',
    "!\"#$%&'()*+,-./:;<=>?@[]^_`{|}~",
    'カタカナ',
    'ガタ゛ダ',
    'ﾊﾟﾋﾞｶﾞ',
    'ｶﾀｶﾅ ﾊﾝｶｸ',
    'ひらがな',
    'がぎぐげご ぱぴぷ',
    '漢字タイトル',
    '日本語のうた',
    'Привет мир',
    'Käße größer Übung',
    'déjà vu à côté',
    'naïve façade',
    'ø æ œ ł đ',
    'Track 01 - ダンス / ど-れ',
    'ａｂｃＡＢＣ１２３',
    '０；Ｔｉｔｌｅ／／',
    '0;My Disc//1-5;Group//',
    '～〜・「」。、',
    'fire track',
    'ハートビート',
    'ヴァイオリン',
];

const ranges = ['1', '1-5', '10-12', '3;', '1/2', '0;'];

const titleVectors = titles.map(title => ({
    input: title,
    encoded: Buffer.from(encodeToSJIS(title)).toString('hex'),
    length_sjis: getLengthAfterEncodingToSJIS(title),
    half_width_length: getHalfWidthTitleLength(title),
    sanitized_half: sanitizeHalfWidthTitle(title),
    sanitized_full: sanitizeFullWidthTitle(title),
    aggressive: aggressiveSanitizeTitle(title),
}));

const decodeVectors = titles.map(title => {
    const encoded = encodeToSJIS(title);
    return {
        input: Buffer.from(encoded).toString('hex'),
        decoded: decodeFromSJIS(encoded),
    };
});

const rangeVectors = ranges.map(range => ({
    input: range,
    full_width: halfWidthToFullWidthRange(range),
}));

process.stdout.write(
    JSON.stringify({ titles: titleVectors, decode: decodeVectors, ranges: rangeVectors }, null, 1)
);
