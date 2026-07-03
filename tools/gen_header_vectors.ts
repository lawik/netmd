// Golden vectors for the AEA/WAV headers produced during track upload.
//
// Run from the netmd-js checkout:
//   npx ts-node -T ../netmd/tools/gen_header_vectors.ts > ../netmd/test/fixtures/header_vectors.json

import { createAeaHeader, createWavHeader } from '../../netmd-js/src/utils';
import { DiscFormat } from '../../netmd-js/src/netmd-interface';

const hex = (u8: Uint8Array) =>
    Array.from(u8)
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');

const aea = [
    { name: '', channels: 2, soundgroups: 1 },
    { name: 'My Track', channels: 2, soundgroups: 4711 },
    { name: 'Mono Song', channels: 1, soundgroups: 212 },
].map(({ name, channels, soundgroups }) => ({
    name,
    channels,
    soundgroups,
    header: hex(createAeaHeader(name, channels, soundgroups)),
}));

const wav = [
    { format: DiscFormat.lp2, bytes: 1000 },
    { format: DiscFormat.lp4, bytes: 123456 },
].map(({ format, bytes }) => ({
    format,
    bytes,
    header: hex(createWavHeader(format, bytes)),
}));

process.stdout.write(JSON.stringify({ aea, wav }, null, 1));
