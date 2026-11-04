// Garante que a URL assinada prende tipo, tamanho e "não sobrescrever".
// Precisa do aws4fetch: no Deno vale o deno.json desta pasta (`deno test`); no
// Node, só com a biblioteca instalada ao lado (npm i aws4fetch@1.0.20).
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { presignPut } from './s3.ts'

const cfg = { accessKeyId: 'AKIAEXEMPLO', secretAccessKey: 'segredo-de-teste', region: 'sa-east-1', bucket: 'bucket-de-teste' }
const path = 'forge/x/123e4567-e89b-42d3-a456-426614174000.webp'

test('a URL assinada inclui content-type, content-length e if-none-match', async () => {
  const { url, headers } = await presignPut(cfg, path, 12345, '20261104T120000Z')
  const u = new URL(url)
  assert.equal(u.host, 'bucket-de-teste.s3.sa-east-1.amazonaws.com')
  assert.equal(u.pathname, `/${path}`)
  assert.equal(u.searchParams.get('X-Amz-Expires'), '300')
  assert.equal(u.searchParams.get('X-Amz-Algorithm'), 'AWS4-HMAC-SHA256')
  assert.ok(u.searchParams.get('X-Amz-Signature'))
  const signed = (u.searchParams.get('X-Amz-SignedHeaders') ?? '').split(';')
  for (const h of ['content-type', 'content-length', 'if-none-match', 'cache-control', 'host']) assert.ok(signed.includes(h), `falta ${h}: ${signed}`)
  assert.equal(headers['Content-Type'], 'image/webp')
  assert.equal(headers['If-None-Match'], '*')
})

test('o tamanho muda a assinatura (está preso)', async () => {
  const a = new URL((await presignPut(cfg, path, 100, '20261104T120000Z')).url).searchParams.get('X-Amz-Signature')
  const b = new URL((await presignPut(cfg, path, 101, '20261104T120000Z')).url).searchParams.get('X-Amz-Signature')
  assert.notEqual(a, b)
})
