-- Reforço do filtro de contato e Pix, v2 (cartão oU0Wl3hI · RN38).
--
-- Quatro frentes: (1) as 21 variantes de ataque já barradas continuam barradas; (2) dígitos Lao e
-- Myanmar viram 0-9 e são barrados; (3) `.tech` entra na lista de TLDs; (4) data normal deixa de
-- ser lida como número de telefone, sem abrir buraco para número de 8 dígitos disfarçado de data.
-- Os textos com dígitos Lao e Myanmar são montados por `translate` a partir de ASCII, para o ponto
-- de código ser exatamente o do bloco Unicode e não depender de como o arquivo foi digitado.

begin;
select no_plan();

create function pg_temp.lao(t text) returns text language sql immutable as
$$ select translate(t, '0123456789', U&'\0ED0\0ED1\0ED2\0ED3\0ED4\0ED5\0ED6\0ED7\0ED8\0ED9') $$;
create function pg_temp.myanmar(t text) returns text language sql immutable as
$$ select translate(t, '0123456789', U&'\1040\1041\1042\1043\1044\1045\1046\1047\1048\1049') $$;

-- (1) As 21 variantes anteriores (11 do Lince Codex R1 e 10 do R2), todas barradas.
select is(privado.texto_sem_contato_ou_pix(t), false, 'barrada, variante anterior: ' || t)
 from (values
  ('segue ＠perfilteste'),
  ('segue ﹫perfilteste'),
  ('pessoa＠exemplo．com'),
  ('perfil．example．com'),
  ('nove ' || chr(8203) || 'oito sete seis cinco quatro três dois'),
  ('nove oito sete seis cinco quatro tre' || chr(770) || 's dois'),
  ('d94bfb19' || chr(8203) || '-0a5d-4fc0-a8e8-3b8f6a5c2d11'),
  ('perfil.exemplo.br'),
  ('perfil.example.xyz'),
  ('example.c' || U&'\043E' || 'm'),
  ('pessoa arroba exemplo ponto com'),
  ('٦١٩٨٨٨٨٧٧٧٧'),
  ('۶۱۹۸۸۸۸۷۷۷۷'),
  ('६१९८८८८७७७७'),
  ('acesse prof.site'),
  ('veja dr.com'),
  ('veja ex.com'),
  ('pix R$ 12345678909'),
  ('zap 61988887777 reais'),
  ('d94bfb19' || U&'\FE0F' || '-0a5d-4fc0-a8e8-3b8f6a5c2d11'),
  ('se' || U&'\2061' || 'is nove oito sete seis cinco quatro três dois')
 ) v(t);

-- (2) Dígitos Lao (U+0ED0-0ED9) e Myanmar (U+1040-1049).
select is(privado.texto_sem_contato_ou_pix(t), false, 'barrado, ' || nome)
 from (values
  ('Lao, celular de 11 dígitos',            pg_temp.lao('61988887777')),
  ('Lao, celular com pontuação',            pg_temp.lao('(61) 98888-7777')),
  ('Lao, palavra de contato e 9 dígitos',   'zap ' || pg_temp.lao('988887777')),
  ('Lao, 8 dígitos soltos',                 pg_temp.lao('98888777')),
  ('Myanmar, celular de 11 dígitos',        pg_temp.myanmar('61988887777')),
  ('Myanmar, celular com pontuação',        pg_temp.myanmar('(61) 98888-7777')),
  ('Myanmar, palavra de contato e 9 dígitos', 'zap ' || pg_temp.myanmar('988887777')),
  ('Myanmar, 8 dígitos soltos',             pg_temp.myanmar('98888777'))
 ) v(nome, t);

-- Sem pegar texto legítimo: poucos dígitos Lao e Myanmar passam, como poucos dígitos ASCII.
select is(privado.texto_sem_contato_ou_pix('Turma ' || pg_temp.lao('42') || ' de ' || pg_temp.myanmar('2019')), true,
  'poucos dígitos Lao e Myanmar não são telefone');

-- (3) `.tech` entra na lista de TLDs.
select is(privado.texto_sem_contato_ou_pix(t), false, 'barrado, domínio .tech: ' || t)
 from (values ('perfil.tech'), ('veja joaodobar.tech'), ('segue meu.site.tech agora'), ('JOAO.TECH')) v(t);
select is(privado.texto_sem_contato_ou_pix('Trabalho com tecnologia e técnica de bar'), true,
  'a palavra tecnologia, sem ponto antes de tech, passa');

-- (4) Datas normais deixam de ser lidas como número de telefone.
select is(privado.texto_sem_contato_ou_pix(t), true, 'passa, data normal: ' || t)
 from (values
  ('Trabalhei de 01/02/2019 até 15/11/2023 como garçom'),
  ('12/05/2020'),
  ('01-10-2022'),
  ('Casamento em 5.6.2021 no Lago Sul'),
  ('Admitido em 31/12/2018, desligado em 1/1/2020')
 ) v(t);

-- A máscara de data não pode abrir buraco: 8 dígitos formatados como data inválida seguem barrados,
-- e a palavra de contato ao lado de uma data continua barrando.
select is(privado.texto_sem_contato_ou_pix(t), false, 'barrado, não é data: ' || t)
 from (values
  ('99.88.7766'), ('61.99.8765'), ('32/13/2020'), ('00/00/2020'),
  ('zap 12/05/2020'), ('12/05/2020 whatsapp'),
  ('01/02/2019 15/11/2023')
 ) v(t);

-- (5) Parecer do Lince no PR #446: data colada a número por extenso ou a dígito é telefone disfarçado.
-- Os três primeiros são os do parecer; os dois seguintes têm 9 itens e a máscara de data também os
-- deixava passar. Antes da máscara, todos eram barrados.
select is(privado.texto_sem_contato_ou_pix(t), false, 'barrado, data colada a outro item: ' || t)
 from (values
  ('seis um nove 12/05/2020'),
  ('nove oito sete 31.12.1999'),
  ('meu numero: nove 9 12/05/2020'),
  ('nove 12/05/2020'),
  ('9 12/05/2020'),
  ('12/05/2020 nove'),
  ('seis um nove 12 05 2020')
 ) v(t);

-- A regra 10 conta número por extenso: dez itens, sem nenhuma máscara.
select is(privado.texto_sem_contato_ou_pix('seis um nove oito oito oito oito sete sete sete'), false,
  'barrado, dez números por extenso seguidos');
select is(privado.texto_sem_contato_ou_pix('um dois três'), true, 'poucos números por extenso passam');

-- E a data sozinha, ou entre palavras comuns, continua passando.
select is(privado.texto_sem_contato_ou_pix(t), true, 'passa, data entre palavras: ' || t)
 from (values
  ('Admitido em 31/12/2018.'),
  ('Fiz o curso em 12/05/2020. Depois, mudei de casa em 31/12/2021.'),
  ('De 01/02/2019, até 15/11/2023, como garçom e barman')
 ) v(t);

-- Nada mudou na superfície: mesma assinatura e mesmos privilégios.
select has_function('privado', 'texto_sem_contato_ou_pix', array['text'], 'a assinatura do filtro é a mesma');
select ok(not has_function_privilege('authenticated', 'privado.texto_sem_contato_ou_pix(text)', 'execute'),
  'authenticated não executa o filtro');
select ok(not has_function_privilege('anon', 'privado.texto_sem_contato_ou_pix(text)', 'execute'),
  'anon não executa o filtro');
select ok(has_function_privilege('service_role', 'privado.texto_sem_contato_ou_pix(text)', 'execute'),
  'service_role executa o filtro');

select * from finish();
rollback;
