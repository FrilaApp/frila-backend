if (!Deno.env.get("AGENDADOR_SECRET")) {
  Deno.env.set("AGENDADOR_SECRET", "frila-teste-segredo-agendador-local");
}
