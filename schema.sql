-- =============================================================================
-- Questionários com link individual (sem login) — Supabase "InAudit Hotel" (acdvblhzzaneddlxqyst).
-- Aplicado em 06/10/2026 como migration `pesquisa_questionarios_com_link`. A página é o index.html desta pasta,
-- publicada no GitHub Pages (repo Rodribm10/innova-pesquisa). Link de cada pessoa: https://rodribm10.github.io/innova-pesquisa/?t=<token>.
--
-- As tabelas ficam no schema `pesquisa`, que a API não expõe. Quem responde só alcança duas funções e as duas
-- exigem o token do convite (32 hex aleatórios): pesquisa_abrir(token) e pesquisa_salvar(token, respostas, enviar).
--
-- NOVO QUESTIONÁRIO (SQL, como service role):
--   insert into pesquisa.questionario (id, titulo, introducao, assinatura, prazo, perguntas) values
--     ('<id>', '<título>', '<texto de abertura; parágrafos separados por linha em branco>', 'Rodrigo', 'AAAA-MM-DD',
--      '[{"id":"q1","bloco":"<seção>","texto":"<pergunta>","ajuda":"<opcional>"}, ...]'::jsonb);
--   insert into pesquisa.convite (questionario_id, nome, papel) values ('<id>', '<nome>', '<papel>') ...;
--   select nome, 'https://rodribm10.github.io/innova-pesquisa/?t=' || token as link from pesquisa.convite where questionario_id = '<id>';
--
-- LER AS RESPOSTAS:
--   select c.nome, r.enviado_em, r.atualizado_em, p ->> 'texto' as pergunta, r.respostas ->> (p ->> 'id') as resposta
--     from pesquisa.convite c join pesquisa.questionario q on q.id = c.questionario_id
--     left join pesquisa.resposta r on r.token = c.token, jsonb_array_elements(q.perguntas) p
--    where q.id = '<id>' order by c.nome, (p ->> 'id');
--
-- ENCERRAR (vira só leitura): update pesquisa.questionario set encerrado = true where id = '<id>';
-- =============================================================================
create schema if not exists pesquisa;
revoke all on schema pesquisa from anon, authenticated;

create table if not exists pesquisa.questionario (
  id          text primary key,
  titulo      text not null,
  introducao  text,
  assinatura  text,
  prazo       date,
  perguntas   jsonb not null,
  encerrado   boolean not null default false,
  criado_em   timestamptz not null default now()
);

create table if not exists pesquisa.convite (
  token           text primary key default replace(gen_random_uuid()::text, '-', ''),
  questionario_id text not null references pesquisa.questionario(id) on delete cascade,
  nome            text not null,
  papel           text,
  criado_em       timestamptz not null default now(),
  unique (questionario_id, nome)
);

create table if not exists pesquisa.resposta (
  token          text primary key references pesquisa.convite(token) on delete cascade,
  respostas      jsonb not null default '{}'::jsonb,
  enviado_em     timestamptz,
  atualizado_em  timestamptz not null default now()
);

alter table pesquisa.questionario enable row level security;
alter table pesquisa.convite      enable row level security;
alter table pesquisa.resposta     enable row level security;

create or replace function public.pesquisa_abrir(p_token text)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
           'nome', c.nome, 'titulo', q.titulo, 'introducao', q.introducao, 'assinatura', q.assinatura,
           'prazo', q.prazo, 'encerrado', q.encerrado, 'perguntas', q.perguntas,
           'respostas', coalesce(r.respostas, '{}'::jsonb), 'enviado_em', r.enviado_em)
    from pesquisa.convite c
    join pesquisa.questionario q on q.id = c.questionario_id
    left join pesquisa.resposta r on r.token = c.token
   where c.token = p_token
$$;

create or replace function public.pesquisa_salvar(p_token text, p_respostas jsonb, p_enviar boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_q       pesquisa.questionario%rowtype;
  v_ids     text[];
  v_chave   text;
  v_valor   jsonb;
  v_limpas  jsonb := '{}'::jsonb;
  v_enviado timestamptz;
begin
  select q.* into v_q from pesquisa.convite c join pesquisa.questionario q on q.id = c.questionario_id where c.token = p_token;
  if not found then raise exception 'link inválido'; end if;
  if v_q.encerrado then raise exception 'questionário encerrado'; end if;
  if p_respostas is null or jsonb_typeof(p_respostas) <> 'object' then raise exception 'respostas inválidas'; end if;
  select array_agg(p ->> 'id') into v_ids from jsonb_array_elements(v_q.perguntas) p;
  for v_chave, v_valor in select key, value from jsonb_each(p_respostas) loop
    if v_chave = any(v_ids) and jsonb_typeof(v_valor) = 'string' then
      v_limpas := v_limpas || jsonb_build_object(v_chave, left(v_valor #>> '{}', 8000));
    end if;
  end loop;
  insert into pesquisa.resposta as r (token, respostas, enviado_em, atualizado_em)
  values (p_token, v_limpas, case when p_enviar then now() end, now())
  on conflict (token) do update
     set respostas = excluded.respostas,
         enviado_em = case when p_enviar then now() else r.enviado_em end,
         atualizado_em = now()
  returning enviado_em into v_enviado;
  return jsonb_build_object('ok', true, 'enviado_em', v_enviado);
end;
$$;

revoke all on function public.pesquisa_abrir(text) from public;
revoke all on function public.pesquisa_salvar(text, jsonb, boolean) from public;
grant execute on function public.pesquisa_abrir(text) to anon, authenticated;
grant execute on function public.pesquisa_salvar(text, jsonb, boolean) to anon, authenticated;
