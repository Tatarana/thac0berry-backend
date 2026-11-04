// Edge Function site-image-upload: envio das imagens do site para o S3
// (desenho em docs/imagens-fora-do-supabase.md). Duas ações, ambas só para o
// admin logado:
//   presign  -> devolve uma URL de PUT assinada (5 min, image/webp, tamanho e
//               caminho presos) para o navegador enviar o arquivo direto ao S3;
//   finalize -> confere por HEAD que o arquivo chegou e registra a versão com
//               add_site_image_version, chamada com o JWT do admin (assim
//               uploaded_by fica certo e a service_role não é usada).
//
// Secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION,
// SITE_IMAGES_BUCKET. SUPABASE_URL e SUPABASE_ANON_KEY o Supabase injeta.
//
// verify_jwt está desligado em supabase/config.toml: o gateway barraria o
// pedido OPTIONS do CORS (que vai sem Authorization). A autorização de verdade
// é is_admin(), chamada aqui com o JWT do usuário em cada ação.
import { PRESIGN_SECONDS, buildObjectPath, checkFinalize, checkHead, checkPresign, corsHeaders, statusOfPgError } from './regras.ts'
import { headObject, presignPut, type S3Config } from './s3.ts'

const json = (body: unknown, status: number, cors: Record<string, string>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

function s3Config(): S3Config | null {
  const accessKeyId = Deno.env.get('AWS_ACCESS_KEY_ID')
  const secretAccessKey = Deno.env.get('AWS_SECRET_ACCESS_KEY')
  const region = Deno.env.get('AWS_REGION')
  const bucket = Deno.env.get('SITE_IMAGES_BUCKET')
  return accessKeyId && secretAccessKey && region && bucket ? { accessKeyId, secretAccessKey, region, bucket } : null
}

/** Chama uma RPC do PostgREST com o JWT do usuário. */
async function rpc(req: Request, name: string, args: Record<string, unknown>): Promise<{ status: number; body: any }> {
  const base = Deno.env.get('SUPABASE_URL')
  const apikey = req.headers.get('apikey') ?? Deno.env.get('SUPABASE_ANON_KEY')
  const auth = req.headers.get('Authorization')
  if (!base || !apikey || !auth) return { status: 401, body: { message: 'sem login' } }
  const res = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey, Authorization: auth, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  })
  const body = await res.json().catch(() => null)
  return { status: res.status, body }
}

async function isAdmin(req: Request): Promise<boolean> {
  const { status, body } = await rpc(req, 'is_admin', {})
  return status === 200 && body === true
}

Deno.serve(async (req) => {
  const cors = corsHeaders(req.headers.get('Origin'))
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (req.method !== 'POST') return json({ error: 'use POST' }, 405, cors)
  // Navegador de outra origem: sem os cabeçalhos CORS ele já não lê a resposta,
  // mas também não vale processar o pedido.
  if (req.headers.get('Origin') && !cors['Access-Control-Allow-Origin']) return json({ error: 'origem não permitida' }, 403, cors)

  const cfg = s3Config()
  if (!cfg) return json({ error: 'função sem as credenciais do bucket' }, 500, cors)

  let body: any
  try {
    body = await req.json()
  } catch {
    return json({ error: 'JSON inválido' }, 400, cors)
  }

  // Valida o formato antes de gastar uma ida ao banco; só depois confere o admin.
  const action = body?.action
  if (action !== 'presign' && action !== 'finalize') return json({ error: 'ação desconhecida' }, 400, cors)
  const presign = action === 'presign' ? checkPresign(body) : null
  const finalize = action === 'finalize' ? checkFinalize(body) : null
  const invalid = [presign, finalize].find((c) => c && !c.ok)
  if (invalid && !invalid.ok) return json({ error: invalid.error }, 400, cors)

  if (!(await isAdmin(req))) return json({ error: 'só o admin troca imagens do site' }, 403, cors)

  if (presign?.ok) {
    const path = buildObjectPath(presign.value.slot, crypto.randomUUID())
    const signed = await presignPut(cfg, path, presign.value.bytes)
    return json({ ...signed, path, expiresIn: PRESIGN_SECONDS }, 200, cors)
  }

  if (!finalize?.ok) return json({ error: 'ação desconhecida' }, 400, cors)
  const { slot, path, width, height } = finalize.value
  let head
  try {
    head = checkHead(await headObject(cfg, path))
  } catch (e) {
    console.error('HEAD no S3 falhou', e)
    return json({ error: 'não foi possível conferir o arquivo no bucket' }, 502, cors)
  }
  if (!head.ok) return json({ error: head.error }, 422, cors)

  const added = await rpc(req, 'add_site_image_version', { p_slot: slot, p_storage_path: path, p_width: width, p_height: height })
  if (added.status !== 200) {
    const status = statusOfPgError(added.body?.code)
    if (status === 500) console.error('add_site_image_version falhou', added.status, added.body)
    return json({ error: status === 500 ? 'não foi possível registrar a versão' : (added.body?.message ?? 'erro') }, status, cors)
  }
  return json({ version: added.body }, 200, cors)
})
