# thac0berry-backend: guia para agentes

Backend Supabase do THAC0berry. Converse com o usuário em **português**; comentários
em português.

## Regras

1. **Proponha e espere o "ok" antes de codar.** Uma entrega por vez.
2. **O desenho manda:** `docs/modelo-de-dados-e-sync.md`. Mudou alguma decisão? Atualize
   o documento na mesma entrega.
3. **Todo o esquema vive em `supabase/migrations/`** (SQL versionado, criado com
   `npx supabase migration new <nome>`). Nunca altere o banco na nuvem pelo painel sem
   a migração correspondente no repo.
4. **Toda tabela com dados de usuário tem RLS ligado** e **testes pgTAP** em
   `supabase/tests/` cobrindo quem lê e quem escreve. Os casos do documento são
   obrigatórios: jogador não lê caderno alheio; jogador vê só o resumo da ficha de
   outro; acesso temporário expira e pode ser revogado; mestre edita fichas da própria
   campanha e só dela.
5. **CI verde antes de entregar** (`.github/workflows/db.yml`): sobe o banco local,
   aplica todas as migrações do zero, roda o lint e os testes.
6. **Segredos nunca no repo:** chaves do Supabase, do Google e da Apple ficam em
   variáveis de ambiente ou nos *secrets* do GitHub. O `.gitignore` bloqueia `.env`,
   `*.p8`, `*.pem` e `*.key`.
7. **Compatibilidade com o app iPad:** a ficha é o JSON do `Codable` do app (coluna
   `data`). Não mude o formato desse JSON aqui; mudanças de formato nascem no app, com
   `schemaVersion` e migração (ver o CLAUDE.md do `thac0berry-ipad`).
8. **O app iPad não usa biblioteca externa:** a API precisa funcionar por HTTP puro
   (`URLSession`). Não dependa de recursos que só existem no SDK `supabase-swift`.
9. Fim de linha: LF (`.gitattributes`). Neste PC o git usa `core.autocrlf=true`.
