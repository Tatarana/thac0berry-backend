// Testes das regras puras. Rodam no Node (>= 22.6) ou no Deno:
//   node --experimental-strip-types --no-warnings=ExperimentalWarning --test supabase/functions/site-image-upload/regras.test.ts
import assert from 'node:assert/strict'
import { test } from 'node:test'
import * as R from './regras.ts'

const uuid = '123e4567-e89b-42d3-a456-426614174000'

test('slot: mesma regra do banco, sem segmento . ou ..', () => {
  assert.ok(R.isValidSlot('forge/race-dwarf-male'))
  assert.ok(R.isValidSlot('monster/beholder.v2'))
  assert.ok(!R.isValidSlot('Forge/x'))
  assert.ok(!R.isValidSlot('forge'))
  assert.ok(!R.isValidSlot('forge/'))
  assert.ok(!R.isValidSlot('forge/../x'))
  assert.ok(!R.isValidSlot('forge/./x'))
  assert.ok(!R.isValidSlot('forge/a b'))
  assert.ok(!R.isValidSlot(42))
})

test('presign: valida slot, tamanho e dimensões', () => {
  const ok = R.checkPresign({ slot: 'forge/x', bytes: 1000, width: 896, height: 1200 })
  assert.deepEqual(ok, { ok: true, value: { slot: 'forge/x', bytes: 1000, width: 896, height: 1200 } })
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: R.MAX_BYTES, width: 1, height: 1 }).ok, true)
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: R.MAX_BYTES + 1, width: 1, height: 1 }).ok, false)
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: 0, width: 1, height: 1 }).ok, false)
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: 1.5, width: 1, height: 1 }).ok, false)
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: '10', width: 1, height: 1 }).ok, false)
  assert.equal(R.checkPresign({ slot: 'x', bytes: 10, width: 1, height: 1 }).ok, false)
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: 10, width: 0, height: 1 }).ok, false)
  assert.equal(R.checkPresign({ slot: 'forge/x', bytes: 10, width: 1 }).ok, false)
  assert.equal(R.checkPresign(null).ok, false)
})

test('finalize: caminho tem de ser <slot>/<uuid>.webp', () => {
  const path = `forge/x/${uuid}.webp`
  assert.deepEqual(R.checkFinalize({ slot: 'forge/x', path, width: 10, height: 20 }), {
    ok: true,
    value: { slot: 'forge/x', path, width: 10, height: 20 },
  })
  // dimensões são opcionais no registro
  assert.equal(R.checkFinalize({ slot: 'forge/x', path }).ok, true)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path, width: -1 }).ok, false)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path: `forge/y/${uuid}.webp` }).ok, false)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path: `forge/x/${uuid}.png` }).ok, false)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path: `forge/x/nome-livre.webp` }).ok, false)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path: `forge/x/sub/${uuid}.webp` }).ok, false)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path: `forge/xy/${uuid}.webp` }).ok, false)
  assert.equal(R.checkFinalize({ slot: 'forge/x', path: `forge/x/../x/${uuid}.webp` }).ok, false)
})

test('caminho do objeto e endereço no S3', () => {
  assert.equal(R.buildObjectPath('forge/x', uuid), `forge/x/${uuid}.webp`)
  assert.equal(R.objectUrl('meu-bucket', 'sa-east-1', `forge/x/${uuid}.webp`), `https://meu-bucket.s3.sa-east-1.amazonaws.com/forge/x/${uuid}.webp`)
})

test('HEAD: existe, image/webp, até 5 MB', () => {
  const ok = { status: 200, contentType: 'image/webp', contentLength: '350000' }
  assert.deepEqual(R.checkHead(ok), { ok: true, value: 350000 })
  assert.equal(R.checkHead({ ...ok, status: 404 }).ok, false)
  assert.equal(R.checkHead({ ...ok, status: 403 }).ok, false)
  assert.equal(R.checkHead({ ...ok, status: 500 }).ok, false)
  assert.equal(R.checkHead({ ...ok, contentType: 'image/png' }).ok, false)
  assert.equal(R.checkHead({ ...ok, contentType: null }).ok, false)
  assert.equal(R.checkHead({ ...ok, contentLength: String(R.MAX_BYTES + 1) }).ok, false)
  assert.equal(R.checkHead({ ...ok, contentLength: String(R.MAX_BYTES) }).ok, true)
  assert.equal(R.checkHead({ ...ok, contentLength: null }).ok, false)
})

test('CORS só para as origens permitidas', () => {
  assert.equal(R.corsHeaders('https://tatarana.github.io')['Access-Control-Allow-Origin'], 'https://tatarana.github.io')
  assert.equal(R.corsHeaders('http://localhost:5174')['Access-Control-Allow-Origin'], 'http://localhost:5174')
  assert.equal(R.corsHeaders('http://localhost:5173')['Access-Control-Allow-Origin'], undefined)
  assert.equal(R.corsHeaders('https://tatarana.github.io.evil.com')['Access-Control-Allow-Origin'], undefined)
  assert.equal(R.corsHeaders(null)['Access-Control-Allow-Origin'], undefined)
})

test('erros do banco viram códigos HTTP', () => {
  assert.equal(R.statusOfPgError('42501'), 403)
  assert.equal(R.statusOfPgError('22023'), 400)
  assert.equal(R.statusOfPgError('23505'), 409)
  assert.equal(R.statusOfPgError(undefined), 500)
})
