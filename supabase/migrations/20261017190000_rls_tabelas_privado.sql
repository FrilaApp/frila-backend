-- Habilita Row Level Security (RLS) nas 9 tabelas internas do schema `privado`
-- que anteriormente não possuíam RLS ativado (defesa em profundidade, achado 1 da AUDITORIA-RLS.md).
--
-- As tabelas pertencem ao papel `postgres` e nenhuma possui FORCE ROW LEVEL SECURITY.
-- Funções SECURITY DEFINER executadas como `postgres` e o papel administrativo `service_role`
-- continuam com acesso pleno, enquanto papéis de API (`anon`, `authenticated`) ficam
-- totalmente bloqueados mesmo sob qualquer concessão acidental de GRANT futuro.

alter table privado.ambiente enable row level security;
alter table privado.auditoria_ciclo enable row level security;
alter table privado.conta_equipe enable row level security;
alter table privado.divergencia_reputacao enable row level security;
alter table privado.parametro_notificacao enable row level security;
alter table privado.termo_bloqueado enable row level security;
alter table privado.texto_da_vaga_ocultado enable row level security;
alter table privado.tipo_no_teto enable row level security;
alter table privado.vaga_ocultada enable row level security;
