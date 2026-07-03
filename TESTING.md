# Test strategy

This library ports netmd-js (primary reference) and libnetmd from
linux-minidisc (secondary reference). Their test suites were surveyed for
reuse:

- **netmd-js** has real unit tests only for its query DSL
  (`query-utils.test.ts`), the layer every protocol command is built on.
  Those cases are ported directly into `test/netmd/query_test.exs`.
  Its remaining test file needs physical hardware and only documents the
  init sequence.
- **libnetmd** has no unit tests (`testdata/` in linux-minidisc belongs to
  the HiMD library). It serves as an independent cross-reference for
  constants and protocol flows, not as a test source.

## Golden vectors

The strongest reuse is executing netmd-js itself as an oracle.
`tools/gen_query_vectors.ts` harvests every literal format string from the
netmd-js protocol layer, feeds deterministic pseudo-random arguments through
the reference `formatQuery`/`scanQuery`/BCD implementations, and writes
`test/fixtures/query_vectors.json`. The ExUnit suite replays every vector
against the Elixir implementation, byte for byte.

The same technique covers the other pure layers: Shift-JIS and title
sanitization (`gen_title_*.ts`), the secure-session DES crypto
(`gen_crypto_vectors.ts`), the AEA/WAV upload headers
(`gen_header_vectors.ts`), and the factory-mode CRC checksum, transfer
crypto and device codes (`gen_factory_vectors.ts`).

Regenerate (requires `npm install` in a sibling `../netmd-js` checkout):

    cd ../netmd-js
    npx ts-node -T ../netmd/tools/gen_query_vectors.ts \
      > ../netmd/test/fixtures/query_vectors.json

## Layers above the DSL

Protocol commands are tested by replaying canned request/reply exchanges
through a mock transport implementing the same behaviour as the USB-backed
one. Exchanges are derived from the format strings both references agree on.
Hardware-dependent behavior (reply polling, interim status backoff) is
exercised against the mock with scripted delays.
