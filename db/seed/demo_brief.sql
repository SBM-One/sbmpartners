-- Made-up demo data for previewing the call brief locally: a Mexican buyer who replied and booked a call, with the
-- messages both ways. Load after the other demo seeds (demo_phone.sql last). If the Santa Fe Rústicos kit is loaded
-- (call_kit_santa_fe_rusticos.sql, with a local client of that name), the demo client gets a copy of it. Every
-- name and number is invented. Never load this into the real Supabase project.

do $$
declare
  cl uuid := 'd0000000-0000-0000-0000-0000000000c1';
  buyer uuid := 'd0000000-0000-0000-0000-00000000b001';
  ana uuid := 'd0000000-0000-0000-0000-00000000b101';
  r uuid; h uuid;
begin
  insert into companies (id, name, type, country, hq_city, hq_state, store_count, categories, style_tags, price_tier, website, phone, notes)
  values (buyer, 'Mueblería Los Arcos', 'retailer', 'MX', 'Querétaro', 'Querétaro', 9, '{comedor,recámara,sala}', '{moderno,contemporáneo}', 'mid',
          'mueblerialosarcos.example', '+52 442 000 3333', 'Cadena regional familiar; abrió 2 tiendas en 2025. Compra hoy a un importador de Asia.');
  insert into contacts (id, company_id, first_name, last_name, title, email, phone, whatsapp, is_decision_maker, country)
  values (ana, buyer, 'Ana', 'Villaseñor', 'Directora de Compras', 'ana@mueblerialosarcos.example', '+52 442 000 3334', '524420003334', true, 'MX'),
         ('d0000000-0000-0000-0000-00000000b102', buyer, 'Jorge', 'Villaseñor', 'Director General', null, null, null, true, 'MX');

  insert into interactions (client_id, company_id, contact_id, channel, direction, kind, actor, subject, body, occurred_at)
  values (cl, buyer, ana, 'email', 'outbound', 'sent', 'staff', 'Recámaras y comedores de madera maciza para Los Arcos',
          'Buen día, Ana. Represento a una fábrica de muebles de madera maciza en Puebla, con línea moderna, marca propia y resurtidos en 30 días. ¿Le interesaría ver el catálogo?',
          now() - interval '9 days');
  insert into interactions (client_id, company_id, contact_id, channel, direction, kind, actor, subject, body, occurred_at, metadata)
  values (cl, buyer, ana, 'email', 'inbound', 'reply', 'buyer', 'Re: Recámaras y comedores de madera maciza para Los Arcos',
          'Hola Santiago. Sí me interesa, sobre todo comedores. Hoy compramos importado y los tiempos nos están matando. ¿Podemos hablar el jueves?',
          now() - interval '2 days', '{"category":"interested","summary":"Le interesan comedores; su importador de Asia tarda demasiado. Pide llamada el jueves."}')
  returning id into r;

  insert into meeting_handoffs (client_id, contact_id, company_id, reply_interaction_id, qualified, interest, product_fit, open_questions, next_steps, body, checks)
  values (cl, ana, buyer, r, true, 'Comedores modernos para 9 tiendas; quiere tiempos más cortos que su importador.',
          'Mesas de comedor y sillas en pino y álamo, línea moderna, precio medio.',
          '["Volumen mensual de comedores","Si reciben en CEDIS o por tienda","Quién más decide (Jorge, director general)"]',
          '["Cerrar muestras pagadas o visita a Chipilo","Mandar catálogo el mismo día"]',
          '# Ana Villaseñor, Mueblería Los Arcos', '[{"key":"interest","status":"yes","evidence":"\"Sí me interesa, sobre todo comedores.\""}]')
  returning id into h;
  perform book_meeting(h, date_trunc('hour', now()) + interval '1 day 2 hours', 'Llamada por teléfono, ella marca', 'yago@sbm-demo.example');

  insert into call_kits (client_id, kit)
  select cl, k.kit from call_kits k join clients c on c.id = k.client_id where c.name = 'Santa Fe Rústicos'
  on conflict (client_id) do update set kit = excluded.kit;
end $$;
