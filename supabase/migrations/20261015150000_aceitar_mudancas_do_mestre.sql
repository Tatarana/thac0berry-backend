-- Combat Tracker interativo, I2 (2026-10-15): o jogador escolhe nas Settings se
-- aceita sozinho as mudanças que o mestre manda ao personagem (dano, cura;
-- `combat_message` com direction 'to_player'). Ligado: o app do jogador aplica
-- na ficha e destaca a mudança, sem ação dele. Desligado (padrão): ele aceita
-- ou recusa cada uma. É lido só pelo app do próprio jogador; as permissões de
-- `user_preferences` não mudam (só o próprio usuário).

alter table public.user_preferences
  add column accept_dm_changes boolean not null default false;
