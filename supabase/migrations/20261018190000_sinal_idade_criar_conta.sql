-- Sinal de idade do cadastro: a faixa, o método e o instante da aferição (ECA Digital).
-- Cartão LQlwDaYZ; parecer em frila-frontend `iOS/Docs/Classificacao18ECA.md`
-- (cartão lJSyGK6q).
--
-- O app consulta a faixa etária do aparelho (Declared Age Range, iOS 26.2+) no cadastro e
-- bloqueia quem aparece como menor. O servidor guardava `nascimento`, `termos_versao` e
-- `termos_aceite_em`, mas não o resultado dessa consulta — e sem ele não há como provar à
-- ANPD **como** a idade foi aferida (Lei 15.211/2025, art. 9º; Decreto 12.880/2026,
-- arts. 24 a 27).
--
-- O que entra, e só isto:
--
--   sinal_idade        o que o aparelho respondeu: `dezoito_ou_mais`, `recusou` ou
--                      `indisponivel`. `abaixo_de_18` nunca chega, porque o app bloqueia
--                      antes; por isso não é valor aceito.
--   idade_aferida_por  `aparelho` quando o sinal foi `dezoito_ou_mais`; `declaracao` nos
--                      outros dois casos, em que valem a data de nascimento e o aceite dos
--                      termos (seção 1 do parecer).
--   idade_aferida_em   o instante, pelo relógio do produto.
--
-- O que **não** entra (Decreto 12.880, art. 24 §3º): data de nascimento vinda do aparelho,
-- identificador do sistema, qualquer coisa além da faixa. O método e o instante são
-- derivados aqui, nunca aceitos do cliente — carimbo enviado pela tela é forjável e não
-- vale como prova. Nenhuma das três colunas sai em `conta_em_json`, nas views de métrica
-- nem na exportação de `meus_dados`; a finalidade é uma só, a prova de conformidade.
--
-- Contas antigas (o app de hoje não envia o parâmetro) ficam com as três colunas nulas.
-- O registro não é apagado na anonimização, pelo mesmo motivo de `termos_versao` e
-- `termos_aceite_em` sobreviverem a ela: é prova de obrigação legal, e não identifica
-- ninguém depois que nome, e-mail, telefone e nascimento saem.

-- ── Colunas ───────────────────────────────────────────────────────────────────

alter table public.usuario
  add column sinal_idade       text,
  add column idade_aferida_por text,
  add column idade_aferida_em  timestamptz;

comment on column public.usuario.sinal_idade is
  'Faixa etária que o aparelho respondeu no cadastro (Declared Age Range): dezoito_ou_mais, recusou ou indisponivel. Nulo para conta criada por app que não envia o sinal. Só a faixa, nunca data ou identificador do aparelho (Decreto 12.880/2026, art. 24 §3º); finalidade única: provar como a idade foi aferida (Lei 15.211/2025, art. 9º).';
comment on column public.usuario.idade_aferida_por is
  'Método da aferição de idade: aparelho (sinal dezoito_ou_mais) ou declaracao (data de nascimento + aceite dos termos, quando o aparelho recusou ou não tinha o sinal). Derivado no servidor a partir de sinal_idade, nunca aceito do cliente.';
comment on column public.usuario.idade_aferida_em is
  'Instante da aferição de idade, pelo relógio do produto (privado.agora()). Nulo quando sinal_idade é nulo.';

-- O CHECK é o que o cartão pede: os três valores, nulo permitido para conta antiga.
alter table public.usuario
  add constraint sinal_idade_valores
    check (sinal_idade in ('dezoito_ou_mais', 'recusou', 'indisponivel'));

-- As três colunas andam juntas: ou nenhuma, ou as três — e o método é função do sinal.
-- Sem isto, um `update` por fora deixaria "faixa sem método" ou "aparelho" num sinal de
-- recusa, e a prova deixaria de dizer o que diz.
--
-- Escrito com `and`/`or`, e não com `case`, de propósito: o `pg_get_constraintdef` de um
-- `case` sai em várias linhas, e o `mutacao.sh` lê cada alvo numa linha só — foi assim que
-- a primeira CI deste PR parou em "RESTAURAÇÃO FALHOU" depois de derrubar esta restrição.
alter table public.usuario
  add constraint idade_aferida_coerente
    check (
         (sinal_idade is null
          and idade_aferida_por is null and idade_aferida_em is null)
      or (sinal_idade = 'dezoito_ou_mais'
          and idade_aferida_por = 'aparelho' and idade_aferida_em is not null)
      or (sinal_idade is not null and sinal_idade <> 'dezoito_ou_mais'
          and idade_aferida_por = 'declaracao' and idade_aferida_em is not null));

-- ── criar_conta ───────────────────────────────────────────────────────────────
--
-- Parâmetro opcional no fim, com `default null`. O `drop` antes do `create` é
-- obrigatório: `create or replace` com outra lista de argumentos criaria uma **segunda**
-- função, e o PostgREST, ao receber o corpo de cinco campos que o app de hoje envia,
-- casaria as duas e recusaria a chamada por ambiguidade. Com uma função só, a chamada
-- sem `sinal_idade` continua idêntica à de antes.

drop function public.criar_conta(public.perfil_conta, text, text, date, text);

create or replace function public.criar_conta(
  perfil        public.perfil_conta,
  nome          text,
  telefone      text,
  nascimento    date,
  termos_versao text,
  sinal_idade   text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid         uuid := (select auth.uid());
  v_email       text;
  v_linha       public.usuario%rowtype;
  v_hoje_sp     date;
  v_aferida_por text;
  v_aferida_em  timestamptz;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_linha from public.usuario u where u.id = v_uid;
  if found then
    if v_linha.perfil is distinct from criar_conta.perfil then
      perform public.erro(409, 'conta_existente', 'perfil_divergente');
    end if;
    return public.conta_em_json(v_linha);
  end if;

  if criar_conta.nome is null or length(btrim(criar_conta.nome)) < 2 then
    perform public.erro(422, 'campo_obrigatorio', 'nome');
  end if;

  -- Diretriz 1.2: o nome aparece para a contraparte no turno e no perfil público.
  if not privado.texto_aceitavel(criar_conta.nome) then
    perform public.erro(422, 'campo_invalido', 'nome');
  end if;

  if criar_conta.telefone is null then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;
  if criar_conta.nascimento is null then
    perform public.erro(422, 'campo_obrigatorio', 'nascimento');
  end if;
  if criar_conta.termos_versao is null or btrim(criar_conta.termos_versao) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'termos_versao');
  end if;

  -- Sinal de idade (cartão LQlwDaYZ): opcional; presente, só os três valores do contrato.
  -- `abaixo_de_18` não está na lista de propósito — o app bloqueia antes de chamar, e um
  -- valor que o servidor não sabe gravar como prova é erro do cliente, não dado.
  if criar_conta.sinal_idade is not null then
    if criar_conta.sinal_idade not in ('dezoito_ou_mais', 'recusou', 'indisponivel') then
      perform public.erro(422, 'campo_invalido', 'sinal_idade');
    end if;
    v_aferida_por := case when criar_conta.sinal_idade = 'dezoito_ou_mais'
                          then 'aparelho' else 'declaracao' end;
    v_aferida_em  := privado.agora();
  end if;

  v_hoje_sp := (privado.agora() at time zone 'America/Sao_Paulo')::date;
  if criar_conta.nascimento > (v_hoje_sp - interval '18 years') then
    perform public.erro(422, 'menor_de_idade');
  end if;

  if criar_conta.telefone !~ '^\+[1-9][0-9]{7,14}$' then
    perform public.erro(422, 'campo_obrigatorio', 'telefone');
  end if;

  select u.email into v_email from auth.users u where u.id = v_uid;
  if v_email is null then
    perform public.erro(401, 'nao_autenticado', 'sem_email_confirmado');
  end if;

  begin
    insert into public.usuario (id, perfil, nome, telefone, email, nascimento,
                                termos_versao, termos_aceite_em,
                                sinal_idade, idade_aferida_por, idade_aferida_em)
    values (v_uid, criar_conta.perfil, btrim(criar_conta.nome), criar_conta.telefone,
            v_email, criar_conta.nascimento,
            btrim(criar_conta.termos_versao), privado.agora(),
            criar_conta.sinal_idade, v_aferida_por, v_aferida_em)
    returning * into v_linha;
  exception
    when unique_violation then
      perform public.erro(409, 'conta_existente', 'email_em_uso');
  end;

  return public.conta_em_json(v_linha);
end $$;

comment on function public.criar_conta(public.perfil_conta, text, text, date, text, text) is
  'Cria a conta do produto depois que o código do e-mail foi confirmado. Perfil fixo (RN25), maioridade verificada em horário de Brasília (RN20), aceite registrado, o nome passa pelo filtro da diretriz 1.2 e, se o app enviar sinal_idade (dezoito_ou_mais, recusou, indisponivel), grava a faixa, o método e o instante da aferição (ECA Digital, cartão LQlwDaYZ) — nada disso volta na resposta.';

revoke execute on function public.criar_conta(public.perfil_conta, text, text, date, text, text)
  from public, anon;
grant  execute on function public.criar_conta(public.perfil_conta, text, text, date, text, text)
  to authenticated;
