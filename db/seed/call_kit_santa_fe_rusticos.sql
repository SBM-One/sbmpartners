-- The call kit for Santa Fe Rústicos: cheat sheet, objection answers and Spanish call script, shown in every
-- per-buyer call brief in the phone app (phone_brief() in db/migrations/0010_call_brief.sql). Real client facts:
-- load it into the real project. Re-running it replaces the kit. Never name past customers in it.
-- Facts: client fact sheet (2026-11-23) and Santiago's call-prep answers (2026-11-26).

insert into call_kits (client_id, kit, updated_by)
select id, $kit${
 "title": "Santa Fe Rústicos",
 "updated": "2026-11-26",
 "rules": [
  "Nunca menciones a sus clientes actuales o pasados, ni por nombre ni con pistas (\"una cadena grande de EE. UU.\"). Si preguntan, di: \"Por confidencialidad no damos nombres de clientes; con gusto le mostramos la planta y las piezas.\"",
  "A compradores mexicanos se cotiza en pesos (MXN). No des precios en dólares.",
  "No prometas crédito, consignación ni descuentos. Las condiciones son 30 % de anticipo y 70 % al embarque, o carta de crédito.",
  "No inventes precios por pieza: la lista de precios aún no la tenemos. Ofrece cotizar con la selección del comprador.",
  "Hablas como Santiago, de SBM Partners, que representa a la fábrica."
 ],
 "facts": [
  {
   "heading": "La fábrica",
   "items": [
    [
     "Quién",
     "Fabricante mexicano de muebles de madera maciza desde 1993. Raíz rústica (herrería, mármol, carpintería) y hoy sobre todo línea moderna y contemporánea."
    ],
    [
     "Planta",
     "20,000 m² en Chipilo, Puebla. 150 trabajadores."
    ],
    [
     "Volumen",
     "75,000 piezas al año. Hoy 30 contenedores al mes, con capacidad para 30 más."
    ],
    [
     "Experiencia",
     "Exporta a EE. UU., España, Alemania e Israel. Cumple requisitos de grandes cadenas: códigos de barras, auditorías y factura CFDI."
    ],
    [
     "Certificaciones",
     "FSC y FTC."
    ],
    [
     "Atención",
     "Un vendedor de planta contesta las llamadas y habla inglés."
    ]
   ]
  },
  {
   "heading": "Qué hace",
   "items": [
    [
     "Categorías",
     "Mesas de comedor, sillas, mesas de centro y laterales, consolas, cómodas, vitrinas, roperos, recámaras completas, centros de entretenimiento y bares."
    ],
    [
     "Maderas",
     "Pino y álamo. El comprador puede mandar su propia tela para tapizados."
    ],
    [
     "Marca propia",
     "Sí. También tiene diseño propio en casa y puede desarrollar diseños del comprador."
    ],
    [
     "Línea rústica",
     "Sí, unos 4 tráileres al mes."
    ],
    [
     "Empaque",
     "Desarmado (KD) o armado."
    ]
   ]
  },
  {
   "heading": "Dinero",
   "items": [
    [
     "Moneda",
     "Para México, en pesos (MXN)."
    ],
    [
     "Tráiler completo",
     "Unos 450,000 MXN entregado en CDMX, Monterrey o Guadalajara. Es mercancía más flete, todo junto."
    ],
    [
     "Pedido mínimo inicial",
     "Unos 175,000 MXN. Mínimo 20 piezas por modelo."
    ],
    [
     "Pago",
     "30 % de anticipo y 70 % al embarque, o carta de crédito irrevocable y confirmada a la vista."
    ],
    [
     "Muestras",
     "Se cotizan según la selección, se pagan por adelantado y no se descuentan del pedido."
    ],
    [
     "Precio mayoreo (interno)",
     "Entre 80 y 390 USD por pieza según el modelo. Solo de referencia para ti: al comprador mexicano se le cotiza en pesos."
    ]
   ]
  },
  {
   "heading": "Tiempos y logística",
   "items": [
    [
     "Muestras",
     "30 días."
    ],
    [
     "Primer pedido",
     "2 meses."
    ],
    [
     "Resurtidos",
     "30 días."
    ],
    [
     "Entrega en México",
     "Tráiler entregado en CDMX, Monterrey o Guadalajara (precio con flete incluido). También entrega en Cuernavaca. Fuera de México, precio LAB (FOB) fábrica."
    ]
   ]
  },
  {
   "heading": "Calidad y garantía",
   "items": [
    [
     "Defectos",
     "Alrededor de 1 %."
    ],
    [
     "Reclamaciones",
     "Se resuelven en 15 días."
    ],
    [
     "Garantía",
     "90 días."
    ],
    [
     "Visitas",
     "Sí, se puede visitar la planta en Chipilo."
    ]
   ]
  },
  {
   "heading": "Ferias",
   "items": [
    [
     "Expo Mueble",
     "No van a estar este año. Si el comprador va, ofrece la visita a la planta en su lugar."
    ]
   ]
  }
 ],
 "objections": [
  {
   "q": "Está caro / En otro lado lo consigo más barato",
   "a": "Entiendo. Para comparar parejo hay que ver el costo puesto en su bodega: nuestro precio ya incluye el flete hasta CDMX, Monterrey o Guadalajara, sin aduana, sin flete marítimo y sin tipo de cambio, porque cotizamos en pesos. Además, como resurtimos en 30 días, usted no tiene que comprar inventario para medio año. ¿Contra qué precio y qué pieza nos está comparando? Con eso le armo una cotización con su selección.",
   "proof": "Tráiler entregado ≈ 450,000 MXN con flete. Resurtido 30 días. Cotización en MXN."
  },
  {
   "q": "¿Por qué no comprar en China o Vietnam?",
   "a": "Por tiempo, riesgo y flexibilidad. De Asia son meses de mar, aduana y dólares, y si algo llega mal ya no hay quién responda rápido. Nosotros estamos en Puebla: el primer pedido sale en 2 meses, los resurtidos en 30 días, llega en tráiler a su bodega con factura CFDI, y las reclamaciones se resuelven en 15 días. Y puede venir a ver la planta y su pedido en producción.",
   "proof": "Planta en Chipilo, 150 personas, 75,000 piezas al año. Factura CFDI. Exporta a EE. UU. y Europa."
  },
  {
   "q": "¿Y la calidad? ¿Qué pasa si llega dañado?",
   "a": "Nuestra tasa de defectos es de alrededor de 1 % y cualquier reclamación se resuelve en 15 días, con 90 días de garantía. Es madera maciza de pino y álamo, con certificación FSC, y la planta ya pasa auditorías de cadenas grandes. Lo mejor es que lo vea usted: le mando muestras o viene a la planta.",
   "proof": "Defectos ~1 %. Reclamaciones en 15 días. Garantía 90 días. FSC. Auditorías y códigos de barras."
  },
  {
   "q": "El flete sale caro / ¿Quién paga el envío?",
   "a": "El precio que le damos ya es puesto en su ciudad: un tráiler completo a CDMX, Monterrey o Guadalajara sale en unos 450,000 pesos, mercancía y flete juntos. No hay cargos sorpresa de flete ni de aduana.",
   "proof": "≈ 450,000 MXN tráiler entregado, flete incluido."
  },
  {
   "q": "Quiero muestras gratis / ¿Las muestras se descuentan del pedido?",
   "a": "Las muestras se cotizan según las piezas que elija y se pagan por adelantado; no se descuentan del pedido. Las tenemos listas en 30 días. Si prefiere no pagar muestras, la otra opción es venir a la planta en Chipilo y ver toda la línea en persona.",
   "proof": "Muestras: 30 días, pagadas, no acreditables."
  },
  {
   "q": "El pedido mínimo es mucho para empezar",
   "a": "Para un primer pedido se puede empezar desde unos 175,000 pesos, con mínimo 20 piezas por modelo. Así prueba la venta en sus tiendas y después resurte en 30 días.",
   "proof": "Mínimo inicial ≈ 175,000 MXN. 20 piezas por modelo. Resurtido 30 días."
  },
  {
   "q": "¿Me dan crédito o pago a 30/60 días?",
   "a": "Trabajamos con 30 % de anticipo y 70 % al embarque, o con carta de crédito irrevocable y confirmada. Así mantenemos los precios que le damos. (No prometas crédito: si insiste, dile que lo consultas con la fábrica.)",
   "proof": "30/70 o carta de crédito."
  },
  {
   "q": "¿Con quién trabajan? Denme referencias",
   "a": "Por confidencialidad no damos nombres de clientes. Sí le puedo decir que exportamos a Estados Unidos, España, Alemania e Israel, que cumplimos requisitos de cadenas grandes (códigos de barras, auditorías, CFDI) y que lo invitamos a ver la planta.",
   "proof": "NUNCA nombres de clientes."
  },
  {
   "q": "Ya tengo proveedor",
   "a": "Perfecto, no le pido que lo cambie. Muchos compradores tienen un segundo proveedor para resurtir rápido o para categorías que su proveedor no hace. ¿Hay alguna categoría donde batallen con tiempos o con calidad?",
   "proof": "Resurtido 30 días. Capacidad para 30 contenedores más al mes."
  },
  {
   "q": "Mándame el catálogo y yo te busco",
   "a": "Claro, se lo mando hoy. Para que no le llegue todo, ¿qué categorías y qué rango de precio le interesan? Y dejemos una fecha para revisarlo juntos 15 minutos.",
   "proof": "[PENDIENTE: catálogo y lista de precios todavía no los tenemos.]"
  },
  {
   "q": "¿Pueden hacer mi diseño o con mi marca?",
   "a": "Sí. Hacemos marca propia y tenemos diseño en casa; también desarrollamos diseños del comprador. Usted puede mandar su propia tela para tapizados.",
   "proof": "Marca propia sí. Diseño propio sí. Tela del cliente sí."
  },
  {
   "q": "¿Cuánto tardan?",
   "a": "Muestras en 30 días, primer pedido en 2 meses y resurtidos en 30 días.",
   "proof": "30 días / 2 meses / 30 días."
  }
 ],
 "script": [
  {
   "stage": "Apertura",
   "goal": "Gracias, quién eres, permiso y agenda en 30 segundos.",
   "lines": [
    "Buen día, {contacto}. Habla Santiago Bonilla, de SBM Partners. Gracias por su tiempo.",
    "Como le comenté, represento a Santa Fe Rústicos, una fábrica de muebles de madera maciza en Chipilo, Puebla, desde 1993.",
    "¿Le parece si tomamos 15 minutos? Le hago unas preguntas para entender qué busca {empresa}, le cuento brevemente qué hace la fábrica y vemos si tiene sentido un siguiente paso."
   ]
  },
  {
   "stage": "Preguntas para calificar",
   "goal": "Escucha más de lo que hablas. Anota las respuestas.",
   "lines": [
    "¿Cuántas tiendas o puntos de venta manejan hoy, y en qué ciudades?",
    "¿Qué categorías de mueble venden más? ¿Comedor, recámara, sala, entretenimiento?",
    "¿Qué estilo se mueve mejor con sus clientes: moderno, contemporáneo, rústico?",
    "Hoy, ¿a quién le compran? ¿Fabricante nacional, importación de Asia, o ambos?",
    "¿Qué es lo que más les cuesta con sus proveedores: precio, tiempos, calidad, reclamaciones?",
    "¿En qué rango de precio de venta al público se mueven las piezas que más venden?",
    "¿Cada cuánto resurten y en qué volúmenes? ¿Compran por tráiler?",
    "¿Les interesa marca propia o diseño exclusivo?",
    "¿Reciben en un CEDIS o en cada tienda? ¿En qué ciudad?",
    "Además de usted, ¿quién más participa en la decisión de dar de alta un proveedor?",
    "¿Tienen fechas clave en las que planean compras (temporadas, Buen Fin, cambio de colección)?"
   ]
  },
  {
   "stage": "Presentación corta",
   "goal": "Solo lo que conecta con lo que te dijeron.",
   "lines": [
    "Por lo que me cuenta, creo que encaja así: (elige 2 o 3 según sus respuestas)",
    "Planta de 20,000 m² y 150 personas; hacemos 75,000 piezas al año y tenemos capacidad para crecer con ustedes.",
    "Comedor, recámara, consolas, vitrinas, centros de entretenimiento y bares, en pino y álamo, desarmado o armado.",
    "Primer pedido en 2 meses y resurtidos en 30 días, entregado en su ciudad con factura CFDI.",
    "Marca propia y diseño en casa; si tienen su diseño, lo desarrollamos.",
    "Defectos alrededor de 1 % y reclamaciones resueltas en 15 días."
   ]
  },
  {
   "stage": "Precio y condiciones",
   "goal": "Da los números claros, en pesos.",
   "lines": [
    "Le cotizamos en pesos. Un tráiler completo entregado en CDMX, Monterrey o Guadalajara anda en unos 450,000 pesos, mercancía y flete juntos.",
    "Para empezar, el primer pedido puede ser desde unos 175,000 pesos, con mínimo 20 piezas por modelo.",
    "Las condiciones son 30 % de anticipo y 70 % al embarque, o carta de crédito.",
    "El precio por pieza depende de los modelos que elija; con su selección le mando la cotización."
   ]
  },
  {
   "stage": "Cierre",
   "goal": "Pide uno de dos siguientes pasos, con fecha.",
   "lines": [
    "Lo más rápido para que vea la calidad es una de dos: le mandamos muestras de las piezas que elija, o viene a conocer la planta en Chipilo. ¿Qué le acomoda más?",
    "Muestras: se cotizan según la selección, se pagan por adelantado y están en 30 días. ¿Qué piezas le gustaría ver?",
    "Visita: ¿qué día de la próxima semana o la siguiente le queda para venir a Chipilo? Yo lo acompaño.",
    "Mientras, le mando hoy el catálogo y la cotización de lo que platicamos. ¿A qué correo y quién más debe recibirlo?"
   ]
  },
  {
   "stage": "Antes de colgar",
   "goal": "Confirma y deja todo por escrito.",
   "lines": [
    "Entonces quedamos en: (repite el siguiente paso, la fecha y quién hace qué).",
    "Le escribo hoy por correo y por WhatsApp con el resumen. Mi WhatsApp es el 222 437 4378.",
    "Gracias, {contacto}. Que tenga buen día."
   ]
  }
 ],
 "pending": [
  "Catálogo y lista de precios: existen, pero todavía no los tenemos. Cuando lleguen, se agregan aquí.",
  "Confirmar si el mínimo de 175,000 MXN ya incluye flete, como el tráiler completo.",
  "Confirmar qué es la certificación \"FTC\" antes de mencionarla en una llamada."
 ]
}$kit$::jsonb, 'santiago@sbmpartners.net'
from clients where name = 'Santa Fe Rústicos'
on conflict (client_id) do update set kit = excluded.kit, updated_by = excluded.updated_by, updated_at = now();

