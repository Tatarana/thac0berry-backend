# Modelo de dados e sincronização

Versão 2, 2026-10-05, aprovada (decisões na seção 8). Movido do repo `thac0berry-ipad`.
**Ainda não implementado:** as migrações entram em `supabase/migrations/`, uma fase por vez.
O texto não depende do backend escolhido. Funciona em Postgres (Supabase, Neon) e em
SQLite (Cloudflare D1), trocando `jsonb` por `json`. Onde a escolha muda algo, está
indicado.

## 1. Ponto de partida (o app hoje)

- Tudo fica num único `Documents/library.json` por aparelho (`CharacterLibrary`):
  campanhas, personagens, magias favoritas e preferência de papel do caderno. O arquivo
  tem `schemaVersion` (hoje 1).
- **Campanha** (`Campaign`) guarda dentro dela as **sessões** (`Session`) e as
  **páginas do caderno** (`NotebookEntry`). O caderno já é da campanha, compartilhado
  por quem joga nela.
- **Personagem** (`PlayerCharacter`) tem uns 70 campos guardados, aponta para a
  campanha por `campaignID` (ou fica sem campanha, o "Sandbox") e guarda dentro dele as
  **folhas de magia** (`SpellSheet`), uma por dia de jogo, ligadas à sessão por
  `sessionID`.
- **Todos os ids já são UUID gerados no aparelho.** Isso é ótimo para sincronizar: o
  aparelho cria registros offline sem pedir id ao servidor.
- **Binários embutidos em base64:** retrato (`portraitImageData`), desenho do caderno
  (`drawingData`) e anotações à tinta da folha (`inkNotes`).
- **Dados de referência** (magias, kits, regras, itens) são JSON estático, com fonte
  única e schemas no repo `thac0berry-data` (o app iPad carrega uma cópia). As fichas apontam para eles por id (`matchedSpellID`,
  `matchedItemID`, `matchedProficiencyID`…).

## 2. Princípios

1. **Offline primeiro no iPad.** O app continua funcionando sem rede, como hoje. O
   servidor é o ponto de encontro entre aparelhos e jogadores, não um pré-requisito
   para jogar.
2. **Sincronizar por registro, não pelo arquivo inteiro.** Uma edição na folha de
   magia de hoje não pode disputar com uma página do caderno escrita por outro
   jogador.
3. **Formato JSON das fichas preservado.** Personagem e folha de magia vão para o
   servidor como documento JSON, o mesmo `Codable` de hoje, com algumas colunas
   extraídas para listar e filtrar. Normalizar 70 campos que mudam toda semana em
   tabelas relacionais custaria caro e não traz ganho: ninguém consulta "todos os
   personagens com Força 18".
4. **Binários fora do JSON:** em armazenamento de arquivos, referenciados por hash.
5. **Dados de referência fora do banco:** arquivos estáticos versionados (CDN), como
   já são. **Os ids de referência são contrato:** nunca renomear um id de magia, kit
   ou item, senão as fichas salvas perdem o vínculo.

## 3. Entidades

| Entidade | Dono | Quem lê | Quem edita | Hoje vive em |
|---|---|---|---|---|
| `user` | (conta) | o próprio | o próprio | não existe |
| `user_preferences` | usuário | o próprio | o próprio | `library.json` (favoritas, papel padrão) |
| `campaign` | quem criou (mestre) | membros | mestre | `Campaign` |
| `campaign_member` | campanha | membros | mestre | não existe |
| `session` | campanha | membros | mestre e jogadores | `Campaign.sessions` |
| `notebook_entry` | **autor** (jogador) | **só o autor** (Q3) | só o autor | `Campaign.notebookEntries` |
| `character` | jogador | completo: dono, mestre, quem tem acesso temporário; **resumo**: demais membros (Q2) | dono, mestre e quem tem acesso temporário (Q1) | `PlayerCharacter` (sem as folhas) |
| `character_grant` | personagem | mestre, dono, beneficiado | mestre (concede e revoga) | não existe |
| `spell_sheet` | personagem | igual à ficha completa do personagem | igual ao personagem | `PlayerCharacter.spellSheets` |
| `attachment` | dono do registro que o usa | igual ao registro | o dono | base64 no JSON |

**Acesso temporário (Q1):** quando um jogador falta, o mestre concede a outro jogador
acesso de edição à ficha do ausente (`character_grant`). O acesso vale até o mestre
revogar ou até `expires_at`. **Assumido:** o padrão é 24 h, para cobrir uma sessão sem
ficar aberto para sempre. O dono continua com acesso total.

**Caderno individual (Q3):** cada jogador lê e escreve só as próprias anotações; nem o
mestre lê. **Por personagem (2026-10-06, pedido do usuário):** cada personagem de cada
jogador tem o seu caderno (`notebook_entry.character_id`), inclusive no Sandbox; a
campanha virou opcional. No iPad é o formato 2 do `library.json`. Anotações "públicas" para a campanha ficam para o futuro. Isso **muda o conceito atual do app**: hoje o
caderno é da campanha e compartilhado no aparelho. Na migração, as páginas existentes
ficam com o dono do aparelho que as enviar primeiro.

**Mudança de forma em relação ao app:** sessões, páginas do caderno e folhas de magia
deixam de ser arrays dentro do pai e viram registros próprios. Para o app, isso vale
só na **camada de sincronização**: o `library.json` local pode continuar aninhado.

## 4. Esboço das tabelas (Postgres)

Toda tabela sincronizável tem as **colunas de sincronização**:

| Coluna | Para quê |
|---|---|
| `id uuid` | O mesmo UUID que o app já gera |
| `version bigint` | Incrementa a cada gravação aceita (controle de concorrência) |
| `updated_at timestamptz` | Hora **do servidor**; o relógio do aparelho não é confiável |
| `updated_by uuid` | Quem gravou por último |
| `change_seq bigint` | Número sequencial global do servidor, usado como cursor do "o que mudou desde…" |
| `deleted_at timestamptz` | Exclusão como marcação (*tombstone*), para outros aparelhos ficarem sabendo |
| `schema_version int` | Versão do formato do `data` (ver §6.6) |

```sql
create table campaign (
  id uuid primary key, owner_id uuid not null references auth.users,
  name text not null, started_date date, notes text, is_archived bool default false,
  enabled_settings text[],            -- null = todas as ambientações
  /* colunas de sincronização */ );

create table campaign_member (
  campaign_id uuid references campaign, user_id uuid references auth.users,
  role text not null check (role in ('gm','player')),      -- quem cria a campanha é 'gm'
  joined_at timestamptz default now(),
  primary key (campaign_id, user_id));

create table session (
  id uuid primary key, campaign_id uuid not null references campaign,
  date date not null, title text, summary text, is_archived bool default false,
  /* colunas de sincronização */ );

create table notebook_entry (
  id uuid primary key,
  character_id uuid references character,           -- caderno por personagem (2026-10-06)
  campaign_id uuid references campaign,             -- opcional desde 2026-10-06
  author_id uuid not null references auth.users,    -- caderno individual (Q3)
  -- futuro: visibility text default 'private' ('private' | 'campaign') para
  -- anotações públicas; entra como coluna nova, sem migrar as existentes
  date timestamptz, title text, text text, kind text, paper_style text,
  drawing_attachment uuid references attachment,
  /* colunas de sincronização */ );

create table character (
  id uuid primary key, owner_id uuid not null references auth.users,
  campaign_id uuid references campaign,          -- null = Sandbox
  -- colunas extraídas do JSON, só para listar e filtrar:
  name text, character_class text, level int, status text,
  portrait_attachment uuid references attachment,
  data jsonb not null,                           -- PlayerCharacter sem spellSheets/portrait
  /* colunas de sincronização */ );

create table character_grant (                    -- acesso temporário (Q1)
  id uuid primary key, character_id uuid not null references character,
  grantee_id uuid not null references auth.users, granted_by uuid not null references auth.users,
  created_at timestamptz default now(),
  expires_at timestamptz not null,               -- padrão: +24 h
  revoked_at timestamptz);

create table spell_sheet (
  id uuid primary key, character_id uuid not null references character,
  session_id uuid references session, date timestamptz, title text,
  ink_attachment uuid references attachment,
  data jsonb not null,                           -- slotBoard, entries, magicItems, wisdomAtCreation, turnUndeadUsed
  /* colunas de sincronização */ );

create table user_preferences (
  user_id uuid primary key references auth.users,
  favorite_spell_ids text[] default '{}', default_notebook_paper_style text,
  /* colunas de sincronização */ );

create table attachment (
  id uuid primary key, owner_id uuid not null references auth.users,
  sha256 text not null, mime text not null, bytes int not null,
  storage_path text not null,                    -- ex.: attachments/<owner>/<sha256>
  created_at timestamptz default now());

create table record_history (                     -- versões anteriores (ver §6.3)
  table_name text, record_id uuid, version bigint, data jsonb,
  replaced_at timestamptz default now(), replaced_by uuid,
  primary key (table_name, record_id, version));
```

**Permissões:** no Supabase, via *Row Level Security*; em backend próprio, na API. Em
resumo:
- `character` e `spell_sheet`: leem e escrevem o dono, o mestre da campanha e quem
  tiver um `character_grant` válido (não revogado nem expirado). Os demais membros
  veem só o resumo: nome, classe, nível e PV, por uma *view* com essas colunas.
- `campaign` e `campaign_member`: membros leem; o mestre edita, convida, remove e
  apaga.
- `session`: membros leem; mestre e jogadores criam e editam.
- `notebook_entry`: só o autor.
- `character_grant`: o mestre cria e revoga; o dono e o beneficiado leem.
- `user_preferences`: só o próprio usuário.

### 4.1 Como ficou na implementação da Fase 1

O esboço acima é o desenho geral. A migração
`supabase/migrations/20261005120000_fase1_sync_pessoal.sql` o implementa com estes
detalhes:
- **Resumo calculado pelo banco.** `character.name`, `character_class`, `level` e
  `status`, e também `spell_sheet.title`, são colunas *geradas* a partir do JSON
  `data`. O cliente não as grava, e elas nunca divergem da ficha.
- **Datas como `timestamptz`.** Inclui `session.date`. A data do dia de magia fica
  dentro do JSON da folha.
- **`spell_sheet.owner_id` e `session.owner_id`** repetem o dono, para simplificar as
  permissões.
- **`conflicted_at`** em toda tabela sincronizável: preenchida quando a gravação
  chegou baseada numa versão antiga (§6.3).
- **`record_history` gravado, mas invisível para o cliente** (RLS sem políticas). A
  leitura e o "restaurar" entram junto com a tela do app, por uma função própria.
- **Sem `campaign_member` nem `character_grant` ainda.** Fase 1 = só o dono. Essas
  tabelas entram na Fase 2, em migração própria.
- **Arquivos:** bucket privado `attachments`, com um caminho por usuário
  (`<user_id>/<sha256>`).
- **Acesso explícito à API** (`20261005150000_acesso_explicito.sql`). O projeto na
  nuvem foi criado com "expose new tables" desligado. Só o usuário logado tem
  acesso: SELECT, INSERT e UPDATE nas tabelas da Fase 1, e SELECT e INSERT em
  `attachment`. Ninguém tem DELETE. O anônimo não acessa nada. A migração revoga
  antes os acessos automáticos do ambiente local, para o CI se comportar como a
  nuvem.

## 5. O que muda no formato do personagem

| Campo | No servidor | Motivo |
|---|---|---|
| `spellSheets` | Vira linhas de `spell_sheet` | Cresce um item por dia de jogo e é editado durante a partida; separado, não conflita com a ficha |
| `portraitImageData` | Vira `attachment` | Binário |
| `lastChangedField`, `recentAutoChanges` | **Não sincroniza** (fica no aparelho) | Estado visual de destaque, não dado do personagem (item D do inventário). Recomendação |
| `lastAppliedLevel`, `lastAppliedAbilities`, `lastAppliedClass` | Sincroniza | Base da janela de consequências; precisa ser igual em todos os aparelhos |
| `spellSlotAllotments` | Sincroniza como está | Legado, mantido para decodificar fichas antigas |
| Todo o resto | `data jsonb` | Mesmo `Codable` de hoje |

`favoriteSpellIDs` existe também em `PlayerCharacter`, mas só como campo legado de
migração (hoje as favoritas são globais, em `CharacterLibrary`). No servidor, só em
`user_preferences`.

## 6. Sincronização

### 6.1 Fluxo
1. **Enviar (push):** o aparelho manda os registros alterados localmente desde o
   último envio, cada um com o `version` em que se baseou (`base_version`).
2. **Servidor:** se `base_version` == `version` atual, aceita, incrementa `version`,
   carimba `updated_at`/`change_seq`. Se não, é um **conflito** (§6.3).
3. **Receber (pull):** "me dê tudo com `change_seq` > meu cursor" e o aparelho aplica
   no `library.json` local. Inclui as exclusões marcadas (tombstones).
4. **Quando:** ao abrir o app, ao voltar para o primeiro plano, a cada N minutos com o
   app aberto e manualmente (botão "Sync"). Tempo real (§9, Fase 3) é opcional.

**Contrato de envio (Fase 1):**
- **Registro novo:** `INSERT` (POST).
- **Registro que o servidor já tem:** `UPDATE` (PATCH `?id=eq.<id>`), **sempre**
  levando o `version` conhecido.
- **Não usar upsert** (`ON CONFLICT DO UPDATE`): o trigger de inserção roda antes e
  apaga a versão-base, e o conflito deixaria de ser detectado.
- **Ordem de envio**, por causa das chaves estrangeiras: `campaign` → `session` →
  `character` → `spell_sheet` → `notebook_entry`.
- **Pull:** `GET` de cada tabela com `change_seq=gt.<cursor>`, ordenado por
  `change_seq`. Como duas transações podem terminar fora de ordem, o cliente puxa com
  uma pequena margem abaixo do cursor e aplica de forma idempotente (por `id` +
  `version`).

### 6.2 O que o app precisa guardar por registro
`version` conhecida do servidor e um marcador de "alterado localmente desde o último
envio". Fica num arquivo de metadados de sincronização ao lado do `library.json`, sem
mexer no formato dele.

### 6.3 Regra de conflito
**A última gravação vence, por registro, sem perder a versão substituída.**
- Quando o push chega com `base_version` antiga, o servidor aceita mesmo assim, guarda
  a versão substituída em `record_history` e devolve um aviso de conflito.
- O app mostra um aviso discreto, do tipo "esta folha foi editada em outro aparelho;
  versão anterior guardada", com opção de restaurar.
- **Por que não juntar campo a campo:** a ficha é editada quase sempre por uma pessoa,
  num aparelho de cada vez. Conflito real é raro, e um merge automático errado numa
  ficha de RPG é pior do que um aviso.
- **Onde o conflito é mais provável: a ficha durante a sessão.** Com o mestre podendo
  editar fichas e o acesso temporário, até três pessoas podem mexer na mesma ficha.
  Proposta: além do histórico, mostrar **"fulano está editando esta ficha"** (presença,
  Fase 3) e, ao conceder acesso temporário, avisar o dono. O caderno, privado por
  autor, não tem conflito entre pessoas.

### 6.4 Exclusões
Nunca apagar a linha: marcar `deleted_at`. O pull leva a marcação aos outros
aparelhos. Uma limpeza periódica remove de verdade as marcações com mais de N meses.

### 6.5 Binários
1. O app calcula o SHA-256 do arquivo.
2. Pergunta se o servidor já tem esse hash; se não, envia.
3. Só depois envia o registro que aponta para o anexo.

Como o mesmo conteúdo gera o mesmo hash, nada é enviado duas vezes.

Limites sugeridos:
- retrato: o app já reduz e comprime em JPEG;
- desenho e tinta: o tamanho do `PKDrawing`. Medir antes de fixar um limite.

### 6.6 Versão de formato
- Cada registro carrega `schema_version`.
- Um aparelho que recebe um registro de versão **maior** do que sabe ler deixa aquele
  registro só para leitura. É a mesma lógica do `isReadOnly` que o `library.json`
  já tem desde a v1.99.2.
- Ao mudar um formato, a migração roda no aparelho que lê o registro, como já é feito
  hoje no `load()`.

### 6.7 Primeira conexão (migração do `library.json`)
- No primeiro login, o app envia tudo o que tem localmente como propriedade do
  usuário, mantendo os mesmos UUIDs.
- Campanhas viram campanhas do usuário, com ele como `owner`.
- **Dois aparelhos com bibliotecas diferentes do mesmo usuário:** como os UUIDs não
  colidem, as duas bibliotecas simplesmente se somam.

## 7. Dados de referência

- Ficam como arquivos estáticos versionados, por exemplo `data/v2026.10.05/*.json`,
  servidos por CDN e validados pelos schemas do repo `thac0berry-data`.
- O app continua com a sua cópia embutida. Baixar atualizações sem atualizar o app é
  uma melhoria opcional, para depois.
- O servidor não precisa importar esses dados para o banco, a menos que alguma
  consulta no servidor precise deles, o que hoje não acontece.

## 8. Decisões (2026-10-05)

| # | Pergunta | Decisão |
|---|---|---|
| Q1 | Papel de Mestre? | **Sim.** O mestre edita as fichas dos jogadores e concede **acesso temporário** à ficha de um jogador para outro (quem faltou à sessão). Ver `character_grant`. |
| Q2 | O que um jogador vê dos outros? | **Resumo** (nome, classe, nível, PV). Com acesso temporário, ficha completa com edição. |
| Q3 | Caderno | **Individual:** as anotações são do jogador; só ele lê e escreve, nem o mestre lê. **Futuro:** anotações "públicas" para a campanha (ver nota em `notebook_entry`). |
| Q4 | Entrar numa campanha | Código curto de convite, que o mestre gera e pode revogar *(sugestão aceita)*. |
| Q5 | Login | **Google + Entrar com Apple.** O app vai para a App Store, e a regra 4.8 da Apple exige "Entrar com Apple" quando há login social. No iPad: Google via `ASWebAuthenticationSession` e Apple via `AuthenticationServices`, os dois frameworks do sistema, sem biblioteca externa. Supabase, Cognito e similares aceitam os dois provedores. |
| Q6 | Web offline? | Não, no início *(sugestão aceita)*. |
| Q7 | Sandbox sincroniza? | Sim *(sugestão aceita)*. |

## 9. Fases sugeridas

1. **Fase 1: backup e sincronização pessoal.** Um usuário, seus aparelhos e a web.
   Sem compartilhamento. Entra `user`, `user_preferences`, `character`, `spell_sheet`,
   `campaign`, `session`, `notebook_entry` e `attachment`, tudo dono = usuário. Já
   resolve "não perder personagens ao trocar de versão no Playgrounds".
2. **Fase 2: campanha compartilhada.** `campaign_member` (mestre e jogadores),
   convites, permissões por campanha, resumo dos personagens dos outros e acesso
   temporário (`character_grant`).
3. **Fase 3 (opcional): tempo real.** Mudanças aparecem durante a sessão sem precisar
   de "Sync" (Supabase Realtime, WebSocket).

## 10. O que muda no app iPad (quando for implementar)

Nada disso é para agora. Fica como lista de impacto:
- **Metadados de sincronização** por registro, num arquivo separado (§6.2). O
  `library.json` não muda de formato.
- **Binários fora do JSON:** passar a gravar retrato, desenho e tinta como arquivos
  locais referenciados por hash. Isso é mudança de formato: `schemaVersion` 2, com
  migração em `load()` e plano aprovado (CLAUDE.md do `thac0berry-ipad`, seção 5).
- **Camada de rede por HTTP com `URLSession`**, sem biblioteca externa, para não
  arriscar o build do Playgrounds. Antes de tudo, fazer o teste mínimo de rede já
  previsto no backlog.
- **Tela de conta:** login, status do sync e botão "Sync".
- **Aviso de conflito com "restaurar versão anterior"** (§6.3).

## 11. Riscos e pontos em aberto

- **Tamanho dos desenhos:** sem medir os `PKDrawing` reais, não dá para estimar custo
  de armazenamento. Medir numa biblioteca real antes da Fase 1.
- **Campos com texto livre que referenciam outros dados por nome,** como `kit` (guarda
  o nome do kit, não o id). Funciona igual no servidor, mas é frágil se um nome mudar.
  Candidato a virar id numa migração futura.
- **Relógio:** tudo que decide ordem de sincronização usa hora ou sequência do
  servidor. As datas de domínio (data da sessão, do dia de magia) continuam vindo do
  aparelho, como hoje.
- **Plano gratuito do Supabase pausa após 7 dias sem uso** (ver análise de backend). O
  app offline-first não quebra com isso, só deixa de sincronizar até o projeto ser
  reativado.

## 12. Consequências de ir para a App Store

A publicação foi decidida em 2026-10-05. Ela traz itens que não existiam no fluxo atual
(só Playgrounds):
- **Apple Developer Program** (US$ 99/ano), necessário para publicar e para
  "Entrar com Apple".
- **Ícone do app é obrigatório na loja.** O ícone hoje está fora do projeto por
  suspeita de derrubar o build no Playgrounds (CLAUDE.md do `thac0berry-ipad`, seção 3). Antes de publicar,
  isso precisa ser resolvido, de preferência com acesso a um Mac/Xcode, ou
  configurando o ícone pela tela de ajustes do próprio Playgrounds.
- **"Entrar com Apple" exige a capability correspondente no app.** É preciso confirmar
  se o Swift Playgrounds permite ativá-la; se não permitir, isso vira mais um motivo
  para um Mac.
- **Política de privacidade e exclusão de conta:** a loja exige uma URL de privacidade e
  uma forma de o usuário apagar a própria conta dentro do app. Entra no escopo da
  Fase 1.
