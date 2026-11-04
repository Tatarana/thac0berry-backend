// Assinatura S3 (SigV4) da função site-image-upload, com aws4fetch.
import { AwsClient, AwsV4Signer } from 'aws4fetch'
import { CACHE_CONTROL, CONTENT_TYPE, PRESIGN_SECONDS, objectUrl } from './regras.ts'

export interface S3Config {
  accessKeyId: string
  secretAccessKey: string
  region: string
  bucket: string
}

export interface Presigned {
  url: string
  /** Cabeçalhos que o navegador TEM de mandar no PUT, iguais aos assinados. */
  headers: Record<string, string>
}

/**
 * URL de PUT assinada (na query string), válida por 5 minutos.
 *
 * `allHeaders: true` é essencial: por padrão o aws4fetch NÃO assina
 * `content-type` nem `content-length` (estão em UNSIGNABLE_HEADERS), e a URL
 * aceitaria qualquer tipo e tamanho. Com a opção, os dois entram em
 * X-Amz-SignedHeaders e o S3 recusa um PUT com valor diferente (403
 * SignatureDoesNotMatch). `if-none-match: *` faz o S3 recusar (412) se o
 * caminho já existir: nada é sobrescrito. O navegador define o Content-Length
 * sozinho, igual ao tamanho do Blob.
 */
export async function presignPut(cfg: S3Config, path: string, bytes: number, datetime?: string): Promise<Presigned> {
  const url = new URL(objectUrl(cfg.bucket, cfg.region, path))
  url.searchParams.set('X-Amz-Expires', String(PRESIGN_SECONDS))
  const signed = {
    'content-type': CONTENT_TYPE,
    'content-length': String(bytes),
    'cache-control': CACHE_CONTROL,
    'if-none-match': '*',
  }
  const signer = new AwsV4Signer({
    method: 'PUT',
    url: url.toString(),
    headers: signed,
    accessKeyId: cfg.accessKeyId,
    secretAccessKey: cfg.secretAccessKey,
    region: cfg.region,
    service: 's3',
    signQuery: true,
    allHeaders: true,
    datetime,
  })
  const { url: signedUrl } = await signer.sign()
  return {
    url: signedUrl.toString(),
    // content-length fica de fora: o navegador não deixa defini-lo e o calcula.
    headers: { 'Content-Type': CONTENT_TYPE, 'Cache-Control': CACHE_CONTROL, 'If-None-Match': '*' },
  }
}

/** HEAD assinado (cabeçalho Authorization) no objeto. */
export async function headObject(cfg: S3Config, path: string): Promise<{ status: number; contentType: string | null; contentLength: string | null }> {
  const client = new AwsClient({ accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey, region: cfg.region, service: 's3', retries: 1 })
  const res = await client.fetch(objectUrl(cfg.bucket, cfg.region, path), { method: 'HEAD' })
  return { status: res.status, contentType: res.headers.get('content-type'), contentLength: res.headers.get('content-length') }
}
