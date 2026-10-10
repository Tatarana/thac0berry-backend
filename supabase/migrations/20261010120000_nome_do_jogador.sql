-- Nome/apelido padrão do jogador (2026-10-10, ajuste 2 da web).
-- Fica nas preferências da conta (Settings) e entra no campo "Player" de
-- todo personagem novo criado por este usuário. Personagens que já existem não
-- mudam (decisão do usuário). Vazio ou nulo = o campo do personagem fica vazio.
-- As permissões de `user_preferences` não mudam (só o próprio usuário).

alter table public.user_preferences
  add column default_player_name text;
