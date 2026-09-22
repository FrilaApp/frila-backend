-- `public.erro` deixa de ser chamável pelo cliente.
--
-- Ela existe para as funções do produto levantarem o envelope de erro do contrato. As
-- funções que a chamam são `security definer` e executam com os privilégios do dono,
-- então nenhuma delas precisa que `authenticated` tenha `execute`.
--
-- Com o `grant`, qualquer sessão logada podia fazer `POST /rpc/erro` e fabricar um erro
-- com o código que quisesse — inútil para atacar o banco, mas suficiente para poluir
-- log e telemetria com códigos que nenhuma regra levantou, e para confundir quem
-- estiver depurando o funil do piloto.

revoke execute on function public.erro(int, text, text) from authenticated;
