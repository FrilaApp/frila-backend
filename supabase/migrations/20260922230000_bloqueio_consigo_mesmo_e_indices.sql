-- Um bug na auxiliar de bloqueio, e os índices que as políticas novas pedem.
--
-- ── `bloqueado_com_estabelecimento` dizia que o membro está bloqueado com a própria casa
--
-- A pergunta que a função existe para responder é: *há bloqueio entre esta conta e
-- algum membro deste estabelecimento?* Como ela só conferia que a conta e um membro
-- aparecem no mesmo bloqueio, o membro que bloqueou alguém satisfazia as duas pontas
-- sozinho — ele é "a conta" e é "o membro" — e ficava bloqueado consigo mesmo.
--
-- Hoje isso é inalcançável: o ramo de `vaga_leitura` que a chama exige perfil de
-- profissional, e `candidatura_leitura` sempre passa o usuário de um profissional. Mas
-- `vagas_abertas`, `candidatos_da_vaga` e `contato_do_turno` vão chamar a mesma
-- auxiliar no cartão seguinte, e a primeira que passar o uid de um membro devolve lista
-- vazia sempre — um bug que se manifesta como "sumiu tudo" e não como erro.
--
-- A Modelagem de Banco de Dados tem a mesma expressão, então a correção vale para os
-- dois lados. Registrado no cartão do documento.

create or replace function privado.bloqueado_com_estabelecimento(conta uuid, estab uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.bloqueio b
                   join public.membro_estabelecimento m
                     on m.usuario_id in (b.autor_id, b.bloqueado_id)
                  where m.estabelecimento_id = estab
                    and conta in (b.autor_id, b.bloqueado_id)
                    -- As duas pontas do bloqueio são pessoas diferentes; sem isto, o
                    -- membro que bloqueou alguém fica bloqueado com o próprio negócio.
                    and m.usuario_id <> conta)
$$;

-- ── Índices de cobertura das chaves estrangeiras por onde as políticas filtram ──
--
-- O advisor de desempenho apontou doze chaves estrangeiras sem índice. A maioria é
-- ruído de banco vazio, mas três são colunas que as políticas de leitura consultam a
-- cada linha — e essas o piloto vai sentir.

create index if not exists membro_por_estabelecimento
  on public.membro_estabelecimento (estabelecimento_id);
create index if not exists candidatura_por_profissional
  on public.candidatura (profissional_id);
create index if not exists despacho_por_profissional
  on public.despacho (profissional_id);
create index if not exists turno_por_posicao
  on public.turno (posicao_id);
create index if not exists avaliacao_por_autor
  on public.avaliacao (autor_id);
create index if not exists ocorrencia_por_autor
  on public.ocorrencia (autor_id);
