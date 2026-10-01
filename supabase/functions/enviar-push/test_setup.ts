if (!Deno.env.get("AGENDADOR_SECRET")) {
  Deno.env.set("AGENDADOR_SECRET", "frila-teste-segredo-agendador-local");
}
if (!Deno.env.get("SUPABASE_URL")) {
  Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");
}
if (!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) {
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "mock-service-role-key-test");
}

