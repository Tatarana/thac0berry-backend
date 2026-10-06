-- Imagem das folhas de desenho do caderno (2026-10-06).
-- O desenho do iPad (PencilKit, em `drawing_attachment`) não abre no
-- navegador. O backup do iPad passou a levar também um PNG de cada folha de
-- desenho; ele fica neste anexo para a web mostrar a folha só para leitura.
-- As permissões de `notebook_entry` não mudam (só o autor).

alter table public.notebook_entry
  add column drawing_image_attachment uuid references public.attachment;

create index notebook_entry_drawing_image_idx on public.notebook_entry (drawing_image_attachment);
