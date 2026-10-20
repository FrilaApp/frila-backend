# Proposta de Sinal Operacional de Demonstração em `verificar_saude`

**Contexto:**
Durante a análise do Item 19 (`entrar-demonstracao`), foi apontado que o log emitido pela Edge Function (`[ALERTA_DEMONSTRACAO]` via `console.error`) é um sinal efêmero restrito aos logs de execução de borda (Supabase / Deno Deploy), não sendo diretamente observável pelo cron de monitoramento operacional do banco (`privado.verificar_saude()`).

**Mecanismo Proposto:**
Como a Edge Function `entrar-demonstracao` já persiste todas as tentativas de códigos incorretos para e-mails declarados na tabela `public.entrada_demonstracao` com `aceita = false`, `criado_em` e `ip_hash`:

O `privado.verificar_saude()` pode aferir diretamente o volume recente de tentativas recusadas na janela móvel de 15 minutos:

```sql
declare
  v_tentativas_recusadas_demo int;
  v_teto_alerta_demo          constant int := 10;
begin
  select count(*)
    into v_tentativas_recusadas_demo
    from public.entrada_demonstracao
   where aceita = false
     and criado_em >= v_agora - interval '15 minutes';

  if v_tentativas_recusadas_demo >= v_teto_alerta_demo then
    perform privado.emitir_alerta(
      'demonstracao_sob_ataque',
      jsonb_build_object(
        'tentativas_recusadas_15min', v_tentativas_recusadas_demo,
        'teto', v_teto_alerta_demo
      )
    );
  end if;
end;
```

**Vantagens da Solução:**
1. **Zero Acoplamento Adicional:** Não requer chamadas HTTP adicionais da Edge Function para RPCs de alerta ou banco durante o processamento do request da Apple.
2. **Resiliência a Spam:** Já filtra apenas e-mails declarados da lista (endereços fora da lista nem chegam a gravar no banco).
3. **Visibilidade Unificada:** O alarme `demonstracao_sob_ataque` passa a fluir pelo pipeline existente de notificações operacionais da Equipe Frila (`q_email` / `privado.emitir_alerta`).
