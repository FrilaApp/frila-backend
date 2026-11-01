# Auditoria de Segredos e Dependências

> **Data da Auditoria:** 01/11/2026 às 17:04  
> **Branch:** `chore/auditoria-segredos-e-dependencias` | **Commit:** `684e681`  
> **Status Geral:** **CONFORME (Nenhum segredo exposto e dependências fixadas)**  

---

## 1. Resumo Executivo

| Métrica | Valor Auditado | Status |
| :--- | :--- | :--- |
| Arquivos na Árvore de Trabalho | 469 | Auditados |
| Commits no Histórico Git | 770 | Auditados |
| Segredos Reais Expostos em Arquivos | 0 | ✓ Conforme |
| Segredos Reais Expostos no Histórico | 0 | ✓ Conforme |
| Fixtures Sintéticas / Placeholders | 30 | ✓ Documentados / Isolados |
| Módulos Deno Externos | 3 (100% fixados) | ✓ Conforme |
| Workflows GitHub Actions | 4 actions (100% commit SHA) | ✓ Conforme |
| Extensões PostgreSQL | 6 declaradas | ✓ Conforme |

---

## 2. Varredura de Credenciais, Chaves e Segredos

### 2.1 Política de Não Exposição e Sanitização
Em estrita observância às regras de segurança do time Frila (*'Nunca: commitar, imprimir ou colar em prompt ou log segredo, chave ou dado pessoal real'*):
- Todos os valores encontrados durante a varredura são imediatamente sanitizados.
- As tabelas de auditoria registram apenas a localização, o tipo, a classificação e a máscara segura com o prefixo do hash SHA-256 do valor.
- Segredos reais nunca são gravados neste documento nem exibidos na saída padrão.

### 2.2 Achados na Árvore de Trabalho

| Arquivo | Linha | Tipo de Segredo | Classificação | Trecho Mascarado |
| :--- | :---: | :--- | :--- | :--- |
| `.env.example` | 8 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `docs/FumacaDaV1.md` | 137 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `docs/TESTES-PGTAP-PADROES.md` | 188 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://u:[REDACTED sha256:148de9c5]@127.0.0.1:1` |
| `scripts/teste-auditoria-segredos-e-dependencias.sh` | 139 | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `scripts/teste-auditoria-segredos-e-dependencias.sh` | 65 | Resend API Key | LEGÍTIMO (Documentação/Script de Auditoria) | `re_si...[REDACTED]...678 (sha256:c337e589)` |
| `scripts/teste-auditoria-segredos-e-dependencias.sh` | 105 | AWS Access Key ID | LEGÍTIMO (Documentação/Script de Auditoria) | `AKIAI...[REDACTED]...PLE (sha256:1a5d44a2)` |
| `supabase/README.md` | 13 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `supabase/functions/.env.exemplo` | 25 | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Placeholder de Exemplo) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `supabase/functions/.env.exemplo` | 1 | Google / Firebase Service Account Key | LEGÍTIMO (Placeholder de Exemplo) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:934e89a0]\n-----END PRIVATE KEY-----` |
| `supabase/functions/despachar/index_test.ts` | 172 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `supabase/functions/despachar/index_test.ts` | 173 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `supabase/functions/despachar/index_test.ts` | 175 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `supabase/functions/despachar/index_test.ts` | 176 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `supabase/functions/despachar/index_test.ts` | 178 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `supabase/functions/despachar/index_test.ts` | 178 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `supabase/functions/enviar-push/index_test.ts` | 92 | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `supabase/functions/enviar-push/index_test.ts` | 1987 | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `supabase/functions/enviar-push/index_test.ts` | 2567 | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `supabase/functions/enviar-push/index_test.ts` | 2638 | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `supabase/functions/enviar-push/index_test.ts` | 113 | Atribuição Genérica de Segredo / Token | LEGÍTIMO (Fixture Sintética de Teste) | `acces...[REDACTED]...45" (sha256:42e959e4)` |
| `supabase/functions/enviar-push/index_test.ts` | 915 | Atribuição Genérica de Segredo / Token | LEGÍTIMO (Fixture Sintética de Teste) | `servi...[REDACTED]...te" (sha256:c31296fb)` |
| `supabase/functions/excluir-conta/index_test.ts` | 8 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://mock:[REDACTED sha256:ec864fe9]@localhost:5432` |
| `supabase/functions/limpar-contas-orfas/index_test.ts` | 7 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://mock:[REDACTED sha256:ec864fe9]@localhost:5432` |
| `supabase/functions/saude/index_test.ts` | 133 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `supabase/functions/saude/index_test.ts` | 134 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `supabase/functions/saude/index_test.ts` | 136 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `supabase/functions/saude/index_test.ts` | 137 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `supabase/functions/saude/index_test.ts` | 139 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `supabase/functions/saude/index_test.ts` | 139 | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `supabase/functions/saude/index_test.ts` | 194 | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://u:[REDACTED sha256:148de9c5]@127.0.0.1:1` |

### 2.3 Achados no Histórico Git

| Commit | Data | Autor | Arquivo(s) | Tipo | Classificação | Trecho Mascarado |
| :---: | :---: | :--- | :--- | :--- | :--- | :--- |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `docs/AuditoriaSegredosEDependencias.md` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `scripts/auditoria-segredos-e-dependencias.sh` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `scripts/teste-auditoria-segredos-e-dependencias.sh` | Resend API Key | LEGÍTIMO (Documentação/Script de Auditoria) | `re_si...[REDACTED]...678 (sha256:c337e589)` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `scripts/teste-auditoria-segredos-e-dependencias.sh` | AWS Access Key ID | LEGÍTIMO (Documentação/Script de Auditoria) | `AKIAI...[REDACTED]...PLE (sha256:1a5d44a2)` |
| `684e681` | 2026-11-01 | Cauê Carneiro | `scripts/teste-auditoria-segredos-e-dependencias.sh` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Documentação/Script de Auditoria) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `8fa9bf0` | 2026-11-01 | Cauê Carneiro | `docs/ChecagemDiariaProd.md` | Postgres URL com Senha | LEGÍTIMO (Placeholder de Exemplo) | `postgresql://postgres.[ref]:[REDACTED sha256:974adebd]@[host]:5432` |
| `8fa9bf0` | 2026-11-01 | Cauê Carneiro | `scripts/checagem-diaria.sh` | Postgres URL com Senha | LEGÍTIMO (Placeholder de Exemplo) | `postgresql://postgres:[REDACTED sha256:08d6dd18]@[HOST]:5432` |
| `b5d209e` | 2026-10-29 | Cauê Carneiro | `docs/FumacaDaV1.md` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `05bb572` | 2026-10-28 | Cauê Carneiro | `.env.exemplo` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `58d6cbc` | 2026-10-28 | Cauê Carneiro | `docs/FumacaDaV1.md` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `e274d83` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `docs/TESTES-PGTAP-PADROES.md` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://u:[REDACTED sha256:148de9c5]@127.0.0.1:1` |
| `ec8fac0` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://u:[REDACTED sha256:148de9c5]@127.0.0.1:1` |
| `4e59db5` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `docs/TESTES-PGTAP-PADROES.md` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://u:[REDACTED sha256:148de9c5]@127.0.0.1:1` |
| `47d9935` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `47d9935` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `dd9f390` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://u:[REDACTED sha256:148de9c5]@127.0.0.1:1` |
| `ad5dcd3` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `ad5dcd3` | 2026-10-16 | João Paulo Albuquerque de Almeida Marques | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/despachar/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/despachar/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/despachar/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/despachar/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/despachar/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/despachar/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://usuario:[REDACTED sha256:b7e94be5]@host-custom:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://supabase:[REDACTED sha256:2bb80d53]@supabase-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `80e40a5` | 2026-10-01 | João Paulo | `supabase/functions/saude/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Fixture Sintética de Teste) | `postgresql://injetada:[REDACTED sha256:b7e94be5]@injetada-host:5432` |
| `9656988` | 2026-09-30 | João Paulo | `supabase/functions/saude/index.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@supabase_db_frila-backend:5432` |
| `ef8899d` | 2026-09-28 | João Paulo | `supabase/functions/enviar-push/index_test.ts` | Atribuição Genérica de Segredo / Token | LEGÍTIMO (Fixture Sintética de Teste) | `servi...[REDACTED]...te" (sha256:c31296fb)` |
| `2a6eb35` | 2026-09-27 | João Paulo | `supabase/functions/limpar-contas-orfas/index.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@supabase_db_frila-backend:5432` |
| `2a6eb35` | 2026-09-27 | João Paulo | `supabase/functions/limpar-contas-orfas/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://mock:[REDACTED sha256:ec864fe9]@localhost:5432` |
| `08a8c05` | 2026-09-26 | João Paulo | `supabase/functions/excluir-conta/index_test.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://mock:[REDACTED sha256:ec864fe9]@localhost:5432` |
| `892d513` | 2026-09-26 | João Paulo | `supabase/functions/.env.exemplo` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Placeholder de Exemplo) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `892d513` | 2026-09-26 | João Paulo | `supabase/functions/.env.exemplo` | Google / Firebase Service Account Key | LEGÍTIMO (Placeholder de Exemplo) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:934e89a0]\n-----END PRIVATE KEY-----` |
| `892d513` | 2026-09-26 | João Paulo | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `892d513` | 2026-09-26 | João Paulo | `supabase/functions/enviar-push/index_test.ts` | Atribuição Genérica de Segredo / Token | LEGÍTIMO (Fixture Sintética de Teste) | `acces...[REDACTED]...45" (sha256:42e959e4)` |
| `29dc58a` | 2026-09-26 | João Paulo | `supabase/functions/despachar/index.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@supabase_db_frila-backend:5432` |
| `29dc58a` | 2026-09-26 | João Paulo | `supabase/functions/despachar/index.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `12d3f3f` | 2026-09-26 | João Paulo | `supabase/functions/.env.exemplo` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Placeholder de Exemplo) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `12d3f3f` | 2026-09-26 | João Paulo | `supabase/functions/.env.exemplo` | Google / Firebase Service Account Key | LEGÍTIMO (Placeholder de Exemplo) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:934e89a0]\n-----END PRIVATE KEY-----` |
| `12d3f3f` | 2026-09-26 | João Paulo | `supabase/functions/enviar-push/index_test.ts` | Chave Privada (RSA/EC/OpenSSH/PGP) | LEGÍTIMO (Fixture Sintética de Teste) | `-----BEGIN PRIVATE KEY-----\n[REDACTED sha256:3021d90e]\n-----END PRIVATE KEY-----` |
| `12d3f3f` | 2026-09-26 | João Paulo | `supabase/functions/enviar-push/index_test.ts` | Atribuição Genérica de Segredo / Token | LEGÍTIMO (Fixture Sintética de Teste) | `acces...[REDACTED]...45" (sha256:42e959e4)` |
| `c7f879d` | 2026-09-26 | João Paulo | `supabase/functions/despachar/index.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@supabase_db_frila-backend:5432` |
| `c7f879d` | 2026-09-26 | João Paulo | `supabase/functions/despachar/index.ts` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `6858610` | 2026-09-23 | Matheus Silva | `supabase/README.md` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |
| `c267bf7` | 2026-09-22 | Matheus Silva | `.env.example` | Postgres URL com Senha | LEGÍTIMO (Ambiente Local / Mock) | `postgresql://postgres:[REDACTED sha256:a942b37c]@127.0.0.1:54322` |

---

## 3. Inventário e Auditoria de Dependências

### 3.1 Edge Functions (Deno / JSR / NPM)

| Especificador | Versão Declarada | Status de Fixação |
| :--- | :---: | :--- |
| `jsr:@std/assert@1.0.19` | `1.0.19` | Fixado (Pin) |
| `npm:pdf-lib@1.17.1` | `1.17.1` | Fixado (Pin) |
| `npm:postgres@3.4.4` | `3.4.4` | Fixado (Pin) |

- **Lockfile de Integridade:** ✓ Presente e íntegro (`deno.lock` na raiz)

### 3.2 GitHub Actions (CI/CD Workflows)

| Action | Referência (SHA) | Tag Anotada | Workflow | Status |
| :--- | :---: | :---: | :--- | :--- |
| `actions/checkout` | `11bd71901b...` | `v4.2.2` | `ci.yml` | Fixado por Commit SHA (Imutável) |
| `denoland/setup-deno` | `22d081ff2d...` | `v2.0.5` | `ci.yml` | Fixado por Commit SHA (Imutável) |
| `docker/login-action` | `c94ce9fb46...` | `v3.7.0` | `ci.yml` | Fixado por Commit SHA (Imutável) |
| `supabase/setup-cli` | `1dedf2c611...` | `v1.7.3` | `ci.yml` | Fixado por Commit SHA (Imutável) |

### 3.3 Ambiente Python e Validação do Contrato

| Pacote Python | Versão Fixada | Origem da Declaração |
| :--- | :---: | :--- |
| `jsonschema_specifications` | `2025.9.1` | `.venv-contrato` |
| `jsonschema` | `4.26.0` | `.venv-contrato` |
| `pyyaml` | `6.0.3` | `.venv-contrato` |
| `referencing` | `0.37.0` | `.venv-contrato` |
| `rpds_py` | `2026.9.1` | `.venv-contrato` |
| `attrs` | `26.1.0` | `.venv-contrato` |
| `PyYAML` | `6.0.2` | `scripts/contrato-responde.sh (declarado)` |

- **Integridade do Contrato (`contrato/openapi.yaml`):** ✓ Íntegro (SHA-256 confere) (`8aa49e0c39e87824...`)

### 3.4 Extensões de Banco de Dados (PostgreSQL / Supabase)

| Extensão | Schema | Migração de Origem | Propósito / Função no Produto |
| :--- | :---: | :--- | :--- |
| `btree_gist` | `extensions` | `20260922150000_extensoes_e_erro.sql` | Índices GIST para exclusão e suporte a restrições temporais |
| `citext` | `extensions` | `20260922150000_extensoes_e_erro.sql` | Campos de texto case-insensitive para e-mails e identificadores |
| `pg_cron` | `public` | `20260926010000_motor_despacho.sql` | Agendamentos recorrentes no banco (reconciliação, fechamento de turnos) |
| `pg_net` | `public` | `20260926010000_motor_despacho.sql` | Disparos assíncronos HTTP (webhooks de despacho e e-mail via Edge Functions) |
| `pgmq` | `public` | `20260924160000_publicar_vaga.sql` | Filas de mensagens transacionais para desacoplamento de eventos |
| `postgis` | `extensions` | `20260922150000_extensoes_e_erro.sql` | Geolocalização, cálculo de distâncias entre vagas e profissionais (RN06) |

---

## 4. Matriz de Riscos e Recomendações

1. **Isolamento de Segredos de Infraestrutura:**
   - O repositório não armazena credenciais em texto claro. Variáveis sensíveis como `RESEND_API_KEY`, `SUPABASE_ACCESS_TOKEN`, `FCM_SERVICE_ACCOUNT` e segredos de despacho são injetados exclusivamente via secrets de ambiente e Supabase Vault (PR #187).
2. **Imutabilidade de CI/CD e Dependências:**
   - 100% das GitHub Actions utilizam commit SHAs imutáveis de 40 caracteres e dependências Deno possuem versões fixadas sem flutuação, prevenindo ataques de sequestro de tag (*supply chain poisoning*).
3. **Extensão pg_net e Fila de Despacho:**
   - Conforme documentado em `docs/PROPOSTA-SEGREDO-DESPACHO.md` (e comprovado pela run da CI no PR #284), segredos não devem trafegar em texto claro em `net.http_post`. A migração para tokens HMAC efêmeros recomendada na proposta elimina a persistência de credenciais na fila.

---

## 5. Como Reproduzir a Auditoria

```bash
# Executa o autoteste completo do auditor
./scripts/teste-auditoria-segredos-e-dependencias.sh

# Executa a auditoria e atualiza este relatório
./scripts/auditoria-segredos-e-dependencias.sh
```
