-- Made-up demo data for previewing the phone app locally: one WhatsApp message, one call script and one LinkedIn
-- note waiting to be sent by hand, plus today's research quota. Load after demo_dashboard.sql, demo_sends.sql and
-- demo_pipeline.sql. Every name and number is invented. Never load this into the real Supabase project.

insert into companies (id, name, type, country, hq_city, phone) values
  ('d0000000-0000-0000-0000-00000000f001', 'Casa Encino Muebles', 'retailer', 'MX', 'Guadalajara', '+52 33 0000 1111'),
  ('d0000000-0000-0000-0000-00000000f002', 'Grupo Tlalli Hoteles', 'hospitality', 'MX', 'Cancún', '+52 998 000 2222');
insert into contacts (id, company_id, first_name, last_name, title, phone, whatsapp, linkedin_url, country) values
  ('d0000000-0000-0000-0000-00000000f101', 'd0000000-0000-0000-0000-00000000f001', null, null, null, '+52 33 0000 1111', '523300001111', null, 'MX'),
  ('d0000000-0000-0000-0000-00000000f102', 'd0000000-0000-0000-0000-00000000f002', 'Lucía', 'Arriaga', 'Gerente de Compras', null, null,
   'https://www.linkedin.com/in/lucia-arriaga-demo', 'MX'),
  ('d0000000-0000-0000-0000-00000000f103', 'd0000000-0000-0000-0000-00000000f002', 'Tomás', 'Ibarra', 'Director de Proyectos FF&E', null, null, null, 'MX');

insert into outreach_drafts (client_id, contact_id, company_id, channel, step, subject, body, status, created_at) values
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-00000000f101', 'd0000000-0000-0000-0000-00000000f001', 'other', 1,
   'WhatsApp +52 33 0000 1111',
   'Buen día. Soy Santiago, de SBM Partners. Represento a una fábrica de muebles de madera maciza en Puebla con línea moderna y opción de marca propia. ¿Me podría compartir el contacto del área de compras? Con gusto les envío el catálogo. Gracias.',
   'pending_review', now() - interval '2 hours'),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-00000000f102', 'd0000000-0000-0000-0000-00000000f002', 'linkedin', 1,
   'Nota de conexión + mensaje',
   E'NOTA DE CONEXIÓN:\nBuen día, Lucía. Represento a una fábrica de muebles de madera maciza en Puebla. Me gustaría presentarla a Grupo Tlalli como proveedor. Será un gusto conectar.\n\nMENSAJE TRAS ACEPTAR:\nGracias por aceptar, Lucía. La fábrica hace habitaciones completas de hotel en pino y álamo, con marca propia o diseño de la cadena. ¿Le parece si le envío el catálogo?',
   'pending_review', now() - interval '90 minutes'),
  ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-00000000f103', 'd0000000-0000-0000-0000-00000000f002', 'call', 1,
   'Llamada +52 998 000 2222',
   'Buen día, habla Santiago, de SBM Partners. ¿Me podría comunicar con el Sr. Tomás Ibarra, de proyectos? Represento a una fábrica de muebles de madera maciza en Puebla. Si no está, ¿me podría dar su correo para enviarle el catálogo? Gracias.',
   'pending_review', now() - interval '1 hour');

insert into research_quota_settings (id) values (true) on conflict (id) do nothing;
insert into screen_pool (source, source_key, name, screened_on, picked)
select 'denue', 'demo-' || g, 'Demo business ' || g, (now() at time zone 'America/Mexico_City')::date, g % 8 = 0
from generate_series(1, 140) g;
