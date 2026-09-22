-- As dezenove políticas de leitura.
--
-- Uma por tabela, todas de `select`, todas para `authenticated`. A escrita já está
-- fechada desde `20260922190000`: nenhuma tabela tem política de insert, update ou
-- delete, e não deve ganhar.
--
-- `auth.uid()` e as auxiliares sem argumento vão dentro de `(select …)`: assim o
-- Postgres calcula o valor uma vez por consulta, e não uma vez por linha.

-- ── Identidade: cada um lê a própria linha, e só ela ───────────────────────────
--
-- RLS filtra linha, não coluna. `usuario` mistura o que a outra parte pode ver (o
-- nome), o que só o dono vê (e-mail e nascimento) e o que tem prazo (o telefone, RN10).
-- Por isso nenhuma política abre a linha de `usuario` para outra pessoa: o que a
-- contraparte vê sai por função `security definer`, que devolve só as colunas
-- permitidas.
create policy usuario_leitura on public.usuario for select to authenticated
  using (id = (select auth.uid()));

-- `profissional` guarda o `ponto_base`, que é quase o endereço de alguém.
create policy profissional_leitura on public.profissional for select to authenticated
  using (usuario_id = (select auth.uid()));

-- ── Estabelecimento ───────────────────────────────────────────────────────────
create policy estabelecimento_leitura on public.estabelecimento for select to authenticated
  using (privado.eh_membro(id));

create policy membro_estabelecimento_leitura on public.membro_estabelecimento
  for select to authenticated
  using (privado.eh_membro(estabelecimento_id));

create policy equipe_confianca_leitura on public.equipe_confianca for select to authenticated
  using (privado.eh_membro(estabelecimento_id)
         or profissional_id = (select privado.meu_profissional_id()));

-- ── Catálogo aberto a quem está logado; a grade, só do dono ───────────────────
create policy funcao_leitura on public.funcao for select to authenticated
  using (true);

create policy profissional_funcao_leitura on public.profissional_funcao
  for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id()));

create policy disponibilidade_leitura on public.disponibilidade for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id()));

-- ── Vaga ──────────────────────────────────────────────────────────────────────
--
-- O membro vê todas as do estabelecimento. O profissional vê as publicadas e as que tem
-- candidatura, menos as de quem tem bloqueio com ele (RF26), e vê sempre as que ocupou,
-- porque o turno é histórico dele e entra na exportação (RF22).
create policy evento_leitura on public.evento for select to authenticated
  using (privado.eh_membro(estabelecimento_id));

create policy vaga_leitura on public.vaga for select to authenticated
  using (
        privado.eh_membro(estabelecimento_id)
     or ((select privado.perfil_da_conta()) = 'profissional'
         and (   privado.ocupa_posicao_na_vaga(id)
              or (not privado.bloqueado_com_estabelecimento(
                        (select auth.uid()), estabelecimento_id)
                  and (estado = 'publicada' or privado.candidatou_na_vaga(id))))));

create policy posicao_leitura on public.posicao for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id())
         or privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id)));

-- ── Candidatura ───────────────────────────────────────────────────────────────
--
-- A própria, ou as das vagas do estabelecimento, menos as de quem tem bloqueio com ele
-- — mesmo que o bloqueio tenha vindo depois da candidatura.
create policy candidatura_leitura on public.candidatura for select to authenticated
  using (
        profissional_id = (select privado.meu_profissional_id())
     or (privado.eh_membro(privado.estabelecimento_da_posicao(posicao_id))
         and not privado.bloqueado_com_estabelecimento(
                   privado.usuario_do_profissional(profissional_id),
                   privado.estabelecimento_da_posicao(posicao_id))));

-- ── Turno: os dois lados da posição ───────────────────────────────────────────
--
-- Fica para os dois mesmo depois de um bloqueio: é histórico de cada um. O bloqueio
-- corta o contato e tudo o que vem depois, não o que já aconteceu.
create policy turno_leitura on public.turno for select to authenticated
  using (privado.lado_da_posicao(posicao_id));

-- ── Avaliação e bloqueio: só quem escreveu ────────────────────────────────────
--
-- Quem foi avaliado vê o agregado — "7 de 7 chamariam de novo" — pela função de perfil,
-- com o denominador (RN08), e não quem respondeu o quê. A resposta individual à vista
-- convidaria à retaliação, e a pergunta binária só funciona se a pessoa responde sem medo.
create policy avaliacao_leitura on public.avaliacao for select to authenticated
  using (autor_id = (select auth.uid()));

-- Quem foi bloqueado apenas deixa de cruzar com a outra parte (RF26). Saber quem o
-- bloqueou é informação que pode pôr alguém em risco.
create policy bloqueio_leitura on public.bloqueio for select to authenticated
  using (autor_id = (select auth.uid()));

-- ── Só do dono ────────────────────────────────────────────────────────────────
--
-- O estabelecimento não vê o despacho: saber quem foi notificado de uma vaga revelaria
-- quem está perto e disponível naquele horário. O contratante vê quem se candidatou, e só.
create policy despacho_leitura on public.despacho for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id()));

create policy notificacao_leitura on public.notificacao for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id()));

create policy dispositivo_leitura on public.dispositivo for select to authenticated
  using (usuario_id = (select auth.uid()));

-- ── Ocorrência ────────────────────────────────────────────────────────────────
--
-- O que a pessoa abriu, e o que foi decidido sobre ela. A denúncia não aparece para o
-- denunciado; ele vê a suspensão, se houver, com o motivo e o caminho para contestar
-- (RN13).
create policy ocorrencia_leitura on public.ocorrencia for select to authenticated
  using (autor_id = (select auth.uid())
         or (usuario_id = (select auth.uid())
             and tipo in ('suspensao', 'cancelamento')));
