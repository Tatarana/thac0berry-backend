# Imagens do site na AWS: passo a passo

Passos 1 a 3 e 6 já executados em 2026-11-04 (conta `025112051097`, `sa-east-1`, bucket
`thac0berry-site-images-025112051097`, distribuição `E2Y49SR3KVKC9Z`,
`d1ve1v7ojhgjr2.cloudfront.net`). Falta a virada (passo 4). A AWS CLI precisa ser de
2022 ou mais nova, por causa do `create-origin-access-control`. Desenho e motivos: `docs/imagens-fora-do-supabase.md`. Os comandos são para o Git
Bash (ou qualquer shell POSIX) com a AWS CLI v2.

| Arquivo | Para quê |
|---|---|
| `cors.json` | CORS do bucket: PUT vindo do site e do `localhost:5174` |
| `oac.json` | Origin Access Control: só o CloudFront lê o bucket |
| `cloudfront-distribution.json` | Distribuição com cache longo (política gerenciada CachingOptimized) |
| `bucket-policy.json` | Política do bucket: leitura só pela distribuição |
| `iam-policy.json` | Política do usuário da Edge Function e dos scripts: grava e lê; nunca apaga |

Os `<…>` dos JSON são preenchidos pelos `sed` abaixo. Nenhuma chave vai para o repo.

## 1. Criar a infraestrutura

Use um perfil com poder de administrador **só para este passo** (não o usuário do
site, que é criado no item 1.6).

```bash
export AWS_PROFILE=<seu-perfil-admin>
export REGION=sa-east-1                       # a que preferir
export BUCKET=thac0berry-site-images-<sufixo-unico>   # nome global; sem pontos
export OUT="$(mktemp -d)"                     # arquivos preenchidos ficam fora do repo
cd infra/site-images
```

**1.1 Bucket privado, versionado, com CORS**

```bash
# us-east-1 não aceita --create-bucket-configuration: tire essa opção se for a região.
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration file://cors.json
```

**1.2 Origin Access Control** (anote o `Id` da resposta)

```bash
aws cloudfront create-origin-access-control --origin-access-control-config file://oac.json
export OAC_ID=<Id da resposta>
```

**1.3 Distribuição CloudFront** (anote `Id` e `DomainName`)

```bash
sed -e "s/<BUCKET>/$BUCKET/" -e "s/<REGION>/$REGION/" -e "s/<OAC_ID>/$OAC_ID/" \
  cloudfront-distribution.json > "$OUT/distribution.json"
aws cloudfront create-distribution --distribution-config "file://$OUT/distribution.json"
export DIST_ID=<Id da resposta>
export CF_DOMAIN=<DomainName, algo como d1234abcd.cloudfront.net>
```

O id `658327ea-f89d-4fab-a63d-7e88639e58f6` é o da política gerenciada
CachingOptimized; confira com `aws cloudfront list-cache-policies --type managed`.

**1.4 Política do bucket** (só agora, que a distribuição existe)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -e "s/<BUCKET>/$BUCKET/" -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/" -e "s/<DISTRIBUTION_ID>/$DIST_ID/" \
  bucket-policy.json > "$OUT/bucket-policy.json"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$OUT/bucket-policy.json"
```

**1.5 Esperar a distribuição** ficar `Deployed` (alguns minutos):
`aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.Status`.

**1.6 Usuário IAM sem permissão de apagar**

```bash
sed "s/<BUCKET>/$BUCKET/" iam-policy.json > "$OUT/iam-policy.json"
aws iam create-user --user-name thac0berry-site-images
aws iam put-user-policy --user-name thac0berry-site-images \
  --policy-name site-images-grava-e-le --policy-document "file://$OUT/iam-policy.json"
aws iam create-access-key --user-name thac0berry-site-images
```

A resposta do último comando mostra a chave secreta **uma única vez**. Guarde-a num
gerenciador de senhas; não a cole no repo, em issue ou em chat.

> `s3:GetObject` é o que a função usa no HEAD de conferência. Sem `s3:ListBucket`, um
> arquivo que não existe responde 403 em vez de 404; a função trata os dois do mesmo
> jeito ("o arquivo não chegou").

## 2. Copiar os arquivos que já existem (primeira passada)

O site continua lendo do Supabase; nada quebra. O script **não apaga nada** nem no
Supabase nem no S3 e pula o que já está no S3, então pode rodar quantas vezes quiser.
No repo `thac0berry-web`:

```bash
export AWS_ACCESS_KEY_ID=<chave do usuário thac0berry-site-images>
export AWS_SECRET_ACCESS_KEY=<segredo>
export AWS_REGION=$REGION
export SITE_IMAGES_BUCKET=$BUCKET
node scripts/copy-site-images-to-s3.mjs --dry-run   # só lista o que copiaria
node scripts/copy-site-images-to-s3.mjs
```

Confira uma imagem: `https://$CF_DOMAIN/<storage_path de qualquer linha>` deve abrir.

## 3. Secrets e função (nada muda para o site ainda)

Num arquivo **fora do repo** (por exemplo `~/site-images.env`, com as quatro linhas
`AWS_ACCESS_KEY_ID=…`, `AWS_SECRET_ACCESS_KEY=…`, `AWS_REGION=…`,
`SITE_IMAGES_BUCKET=…`):

```bash
cd thac0berry-backend
npx -y supabase@2.119.0 secrets set --env-file ~/site-images.env --project-ref azydmvnlzmyvtsgfogbq
npx -y supabase@2.119.0 functions deploy site-image-upload --project-ref azydmvnlzmyvtsgfogbq
```

O deploy lê `verify_jwt = false` de `supabase/config.toml` (necessário para o CORS; a
autorização é `is_admin()` dentro da função). Apague o arquivo `.env` depois.
A função nova só é chamada pela web nova, então publicá-la antes não muda nada.

## 4. A virada (esta ordem; o site nunca fica quebrado)

1. **Última cópia dos arquivos** (passo 2 de novo): pega o que o painel antigo enviou
   ao Supabase desde a primeira passada.
2. **Troque o marcador** em `thac0berry-web/src/config.ts` (`SITE_IMAGES_BASE_URL`) por
   `https://$CF_DOMAIN`, faça o merge do PR da web e deixe o GitHub Pages publicar.
   A web nova lê do CloudFront (os arquivos já estão lá). O envio pelo lápis ainda
   **falha com mensagem genérica** (a migração antiga confere o Supabase Storage); só o
   admin percebe, nenhuma versão é registrada e o arquivo enviado fica órfão no S3.
3. **Aplique a migração** logo em seguida:
   `npx -y supabase@2.119.0 db push --project-ref azydmvnlzmyvtsgfogbq`
   (confira antes com `db push --dry-run`). A partir daí o envio pelo lápis funciona.
4. **Teste**: troque uma imagem pelo lápis, recarregue, volte para a versão anterior.
5. **Passada final de cópia** (passo 2), por garantia.

**Por que a web antes da migração, e não o contrário?** Depois da migração e antes da
web nova, o painel antigo (ainda publicado) envia o arquivo ao Supabase Storage e
registra a versão, sem a migração reclamar de nada. Essa versão passaria a existir só
no Supabase, e a web nova (que lê do CloudFront) mostraria imagem quebrada nesse slot.
É recuperável (a passada de cópia leva o arquivo ao S3), mas é evitável: com a ordem
acima, a janela entre os passos 2 e 3 só impede o envio, não corrompe nada. Se você
for o único admin e não enviar imagens nesse intervalo, as duas ordens são seguras.

## 5. Voltar atrás

- **Só trocar o endereço:** volte `SITE_IMAGES_BASE_URL` ao endereço do Supabase Storage
  (`<SUPABASE_URL>/storage/v1/object/public/site-images`) e publique. O bucket
  `site-images` do Supabase não foi tocado. Atenção: versões criadas **depois** da
  virada existem só no S3; nelas, ou copie os arquivos de volta ao Supabase Storage,
  ou use o lápis para escolher uma versão anterior (que está nos dois lugares).
- **Migração:** não precisa reverter para o site voltar a funcionar (a função nova só
  afrouxa uma checagem). Para restaurar a checagem em `storage.objects`, crie uma
  migração nova com o corpo antigo de `add_site_image_version` (em
  `20261103094627_admin_e_imagens_do_site.sql`).
- Apagar o bucket do Supabase é uma decisão à parte, só depois de a migração se provar.

## 6. Conferir a assinatura (recomendado antes da virada)

Testado em 2026-11-04 contra o S3 real, com `presignPut` rodando localmente e as
credenciais do usuário do site: tipo `image/png`, tamanho diferente e outro caminho
dão 403 `SignatureDoesNotMatch`; o PUT correto dá 200; repeti-lo dá 412; apagar dá 403
`AccessDenied`; ler direto no S3 sem login dá 403. O objeto criado nesse teste ficou em
`forge/_teste-s3/`. Falta o fluxo completo com login de admin, pelo lápis (passo 4.4).
