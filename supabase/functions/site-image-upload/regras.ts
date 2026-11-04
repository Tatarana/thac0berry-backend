// Regras puras da Edge Function site-image-upload: sem rede, sem Deno, sem
// biblioteca. Rodam também no Node (ver regras.test.ts).

/** Mesma regra da coluna site_image_version.slot no banco. */
export const SLOT_RE = /^[a-z0-9-]+(\/[a-z0-9._-]+)+$/

/** Arquivo enviado pela função: `<uuid>.webp` (o caminho inteiro é `<slot>/<uuid>.webp`). */
const FILE_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.webp$/

export const MAX_BYTES = 5 * 1024 * 1024 // 5 MB, como o bucket antigo
export const MAX_DIMENSION = 10000
export const CONTENT_TYPE = 'image/webp'
/** Cada caminho é um arquivo que nunca muda: cache de um ano. */
export const CACHE_CONTROL = 'public, max-age=31536000, immutable'
/** Validade da URL de envio, em segundos. */
export const PRESIGN_SECONDS = 300

/** Origens que podem chamar a função pelo navegador. */
export const ALLOWED_ORIGINS = ['https://tatarana.github.io', 'http://localhost:5174']

export type Checked<T> = { ok: true; value: T } | { ok: false; error: string }

const fail = (error: string): { ok: false; error: string } => ({ ok: false, error })

/**
 * Slot válido: a regra do banco, mais a recusa de segmentos `.` e `..`, que uma
 * URL normalizaria e levariam a assinatura para outro caminho.
 */
export function isValidSlot(slot: unknown): slot is string {
  return typeof slot === 'string' && slot.length <= 200 && SLOT_RE.test(slot) && !slot.split('/').some((part) => part === '.' || part === '..')
}

const isDimension = (n: unknown): n is number => typeof n === 'number' && Number.isInteger(n) && n >= 1 && n <= MAX_DIMENSION

export interface PresignInput {
  slot: string
  bytes: number
  width: number
  height: number
}

/** Confere o corpo do pedido `presign`. */
export function checkPresign(body: unknown): Checked<PresignInput> {
  if (typeof body !== 'object' || body === null) return fail('corpo inválido')
  const b = body as Record<string, unknown>
  if (!isValidSlot(b.slot)) return fail('slot inválido')
  if (typeof b.bytes !== 'number' || !Number.isInteger(b.bytes) || b.bytes < 1) return fail('tamanho inválido')
  if (b.bytes > MAX_BYTES) return fail('arquivo maior que 5 MB')
  if (!isDimension(b.width) || !isDimension(b.height)) return fail('largura e altura inválidas')
  return { ok: true, value: { slot: b.slot, bytes: b.bytes, width: b.width, height: b.height } }
}

export interface FinalizeInput {
  slot: string
  path: string
  width: number | null
  height: number | null
}

/** O caminho está dentro da pasta do slot e tem o formato `<slot>/<uuid>.webp`? */
export function isPathInSlot(slot: string, path: unknown): path is string {
  return typeof path === 'string' && path.startsWith(`${slot}/`) && FILE_RE.test(path.slice(slot.length + 1))
}

/** Confere o corpo do pedido `finalize`. */
export function checkFinalize(body: unknown): Checked<FinalizeInput> {
  if (typeof body !== 'object' || body === null) return fail('corpo inválido')
  const b = body as Record<string, unknown>
  if (!isValidSlot(b.slot)) return fail('slot inválido')
  if (!isPathInSlot(b.slot, b.path)) return fail('o caminho tem de ser <slot>/<uuid>.webp, dentro da pasta do slot')
  const dim = (v: unknown) => (v === undefined || v === null ? null : isDimension(v) ? v : undefined)
  const width = dim(b.width)
  const height = dim(b.height)
  if (width === undefined || height === undefined) return fail('largura e altura inválidas')
  return { ok: true, value: { slot: b.slot, path: b.path, width, height } }
}

/** O caminho novo de um envio. */
export const buildObjectPath = (slot: string, uuid: string) => `${slot}/${uuid}.webp`

/** Endereço do objeto no S3 (estilo virtual-hosted), com cada segmento codificado. */
export function objectUrl(bucket: string, region: string, path: string): string {
  return `https://${bucket}.s3.${region}.amazonaws.com/${path.split('/').map(encodeURIComponent).join('/')}`
}

/** Confere a resposta do HEAD no objeto enviado. */
export function checkHead(head: { status: number; contentType: string | null; contentLength: string | null }): Checked<number> {
  if (head.status === 404 || head.status === 403) return fail('o arquivo não chegou ao bucket')
  if (head.status !== 200) return fail(`o bucket respondeu ${head.status}`)
  if (head.contentType !== CONTENT_TYPE) return fail('o arquivo não é image/webp')
  const bytes = Number(head.contentLength)
  if (!Number.isInteger(bytes) || bytes < 1) return fail('tamanho do arquivo desconhecido')
  if (bytes > MAX_BYTES) return fail('arquivo maior que 5 MB')
  return { ok: true, value: bytes }
}

/** Cabeçalhos CORS para a origem do pedido (vazios se a origem não é permitida). */
export function corsHeaders(origin: string | null): Record<string, string> {
  if (!origin || !ALLOWED_ORIGINS.includes(origin)) return { Vary: 'Origin' }
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  }
}

/** Código HTTP para o erro devolvido pelo PostgREST ao chamar a RPC. */
export function statusOfPgError(code: string | undefined): number {
  if (code === '42501') return 403
  if (code === '22023' || code === '22P02') return 400
  if (code === '23505') return 409
  return 500
}
