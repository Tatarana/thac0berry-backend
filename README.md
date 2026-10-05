# thac0berry-backend

Backend do THAC0berry (ficha de AD&D 2e): contas, campanhas com mestre e jogadores,
sincronização das fichas entre iPad e web. Feito sobre **[Supabase](https://supabase.com)**
(Postgres, login, armazenamento de arquivos). Não há servidor próprio para manter: o
"backend" é o esquema do banco, as regras de permissão e, se preciso, funções em
TypeScript.

| Repo | Papel |
|---|---|
| [`thac0berry-ipad`](https://github.com/Tatarana/thac0berry-ipad) | App iPad (SwiftUI, Swift Playgrounds) |
| [`thac0berry-web`](https://github.com/Tatarana/thac0berry-web) | App web (Vite + React + TypeScript) |
| [`thac0berry-data`](https://github.com/Tatarana/thac0berry-data) | Dados de referência (JSON) e schemas |
| **este** | Banco, permissões, sincronização |

## Desenho

O modelo de dados, as permissões e as regras de sincronização estão em
[`docs/modelo-de-dados-e-sync.md`](docs/modelo-de-dados-e-sync.md) (aprovado em
2026-10-05). Resumo:
- **Offline primeiro** no iPad; sincroniza por registro (ficha, folha de magia,
  sessão, página do caderno).
- **Mestre** edita as fichas da campanha e concede acesso temporário à ficha de um
  jogador para outro.
- **Caderno individual.**
- **Login com Google e "Entrar com Apple".**

## Estrutura

```
supabase/
  config.toml        configuração do projeto local (gerada pelo `supabase init`)
  migrations/        esquema do banco e permissões (RLS), em SQL versionado
  tests/             testes pgTAP (permissões, regras)
docs/                modelo de dados e sincronização
.github/workflows/   CI: sobe o banco local, aplica as migrações e roda os testes
```

## Rodar localmente

Requer Docker e Node.

```bash
npx supabase start      # sobe Postgres, Auth, Storage etc. em containers
npx supabase test db    # roda os testes de supabase/tests
npx supabase stop
```

O projeto na nuvem do Supabase só será criado quando a primeira fase estiver pronta.
