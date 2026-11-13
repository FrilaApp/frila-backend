-- Sobe a versão mínima do iOS para 1.1.0 em privado.configuracao_app (Política v1.1).
-- Com a versão 1.1.0 publicada na App Store, o app 1.0 (versão de build anterior)
-- passa a receber atualização obrigatória na abertura (contrato 0.2.16+ / RN46).
-- A versão recomendada acompanha para sustentar a restrição recomendada_nao_abaixo_da_minima.
-- Android e recursos (foto_de_perfil, chamada_direta, perfil_rico, checkin_por_codigo)
-- permanecem inalterados.

select set_config('lock_timeout', '2s', true);

update privado.configuracao_app
   set versao_minima      = '1.1.0',
       versao_recomendada = '1.1.0',
       atualizado_em      = now()
 where plataforma = 'ios';
