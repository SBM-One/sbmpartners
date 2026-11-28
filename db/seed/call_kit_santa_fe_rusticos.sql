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
 "flow": [
  {
   "n": 1,
   "title": "Saludo",
   "say": [
    "Buen día, {contacto}. Habla Santiago Bonilla, de SBM Partners. Gracias por tomar la llamada.",
    "¿Tiene unos 15 minutos ahora, como quedamos?"
   ],
   "branches": [
    {
     "if": "Sí / Adelante",
     "go": 2
    },
    {
     "if": "Ahora no puedo",
     "say": "Claro, no se preocupe. ¿Le acomoda mejor hoy más tarde o mañana a las 10?",
     "go": 15,
     "note": "Agenda la nueva hora y cierra con el paso 15."
    }
   ]
  },
  {
   "n": 2,
   "title": "Cómo va a ser la llamada",
   "say": [
    "Perfecto. Le propongo esto: primero le hago unas preguntas sobre {empresa}, luego le cuento en dos minutos qué hace la fábrica, y al final vemos juntos si tiene sentido un siguiente paso. ¿Le parece bien?"
   ],
   "branches": [
    {
     "if": "Sí",
     "go": 3
    }
   ]
  },
  {
   "n": 3,
   "title": "Quién representas",
   "say": [
    "Le cuento muy rápido: represento a Santa Fe Rústicos, una fábrica de muebles de madera maciza en Chipilo, Puebla. Llevan desde 1993, tienen 150 personas y hacen 75,000 piezas al año. Hoy lo fuerte es línea moderna y contemporánea en pino y álamo.",
    "Pero antes de hablar de la fábrica, quiero entender a {empresa}."
   ],
   "branches": [
    {
     "if": "(sigue sin esperar respuesta)",
     "go": 4
    }
   ]
  },
  {
   "n": 4,
   "title": "Pregunta: tiendas",
   "say": [
    "¿Cuántas tiendas manejan hoy, y en qué ciudades están?"
   ],
   "branches": [
    {
     "if": "Cualquier respuesta",
     "note": "Anota el número de tiendas y las ciudades.",
     "go": 5
    }
   ]
  },
  {
   "n": 5,
   "title": "Pregunta: qué venden",
   "say": [
    "¿Qué categorías de mueble les dejan más: comedor, recámara, sala o centros de entretenimiento?"
   ],
   "branches": [
    {
     "if": "Comedor, recámara, entretenimiento, guardado",
     "say": "Muy bien, justo eso es lo fuerte de la fábrica.",
     "go": 6
    },
    {
     "if": "Sobre todo salas tapizadas o colchones",
     "say": "Eso no es lo nuestro. Lo fuerte de la fábrica es comedor, recámara y muebles de guardado. ¿Cómo les va en esas categorías?",
     "go": 6
    }
   ]
  },
  {
   "n": 6,
   "title": "Pregunta: a quién le compran",
   "say": [
    "Hoy, ¿a quién le compran esas piezas? ¿A un fabricante nacional, importan, o un poco de ambos?"
   ],
   "branches": [
    {
     "if": "Importamos (China, Vietnam, Asia)",
     "say": "Entiendo. ¿Y cómo les va con los tiempos de entrega y con las reclamaciones cuando algo llega mal?",
     "go": 7
    },
    {
     "if": "A un fabricante nacional",
     "say": "Perfecto. Si pudiera cambiarle una cosa a su proveedor actual, ¿cuál sería?",
     "go": 7
    },
    {
     "if": "Ya tengo proveedor y estoy contento",
     "obj": 8,
     "go": 7
    }
   ]
  },
  {
   "n": 7,
   "title": "Pregunta: qué les duele",
   "say": [
    "¿Qué es lo que más les cuesta hoy con sus proveedores: el precio, los tiempos de entrega, la calidad o resurtir rápido?"
   ],
   "branches": [
    {
     "if": "Precio",
     "note": "En el paso 10 abre con precio puesto en su ciudad y en pesos.",
     "go": 8
    },
    {
     "if": "Tiempos o resurtido",
     "note": "En el paso 10 abre con 2 meses el primer pedido y 30 días los resurtidos.",
     "go": 8
    },
    {
     "if": "Calidad o reclamaciones",
     "note": "En el paso 10 abre con 1 % de defectos y reclamaciones en 15 días.",
     "go": 8
    }
   ]
  },
  {
   "n": 8,
   "title": "Pregunta: volumen",
   "say": [
    "¿Cada cuánto resurten, y más o menos de cuánto es un pedido? ¿Llegan a comprar por tráiler completo?"
   ],
   "branches": [
    {
     "if": "Compran por tráiler o más",
     "note": "Buen tamaño. Sigue.",
     "go": 9
    },
    {
     "if": "Pedidos chicos",
     "note": "Recuerda: el primer pedido mínimo es de unos 175,000 pesos (paso 11).",
     "go": 9
    }
   ]
  },
  {
   "n": 9,
   "title": "Pregunta: logística y decisión",
   "say": [
    "¿La mercancía la reciben en un CEDIS o en cada tienda? ¿En qué ciudad?",
    "Y además de usted, ¿quién más participa en la decisión de dar de alta un proveedor nuevo?"
   ],
   "branches": [
    {
     "if": "Cualquier respuesta",
     "note": "Anota ciudad de entrega y quién más decide. Si hay otra persona, invítala a la visita del paso 14.",
     "go": 10
    }
   ]
  },
  {
   "n": 10,
   "title": "Presentación (2 minutos)",
   "say": [
    "Gracias, {contacto}. Por lo que me cuenta, creo que le podemos ayudar en tres cosas.",
    "Uno: tiempos. El primer pedido sale en 2 meses y los resurtidos en 30 días, así no tiene que comprar inventario para medio año.",
    "Dos: precio puesto en su ciudad. Le cotizamos en pesos, con el flete incluido hasta CDMX, Monterrey o Guadalajara, y con factura CFDI. Sin aduana y sin tipo de cambio.",
    "Tres: calidad. Es madera maciza con certificación FSC, la tasa de defectos es de alrededor de 1 % y cualquier reclamación se resuelve en 15 días.",
    "Además hacemos marca propia y diseño a la medida si lo necesitan. ¿Cómo lo ve hasta aquí?"
   ],
   "branches": [
    {
     "if": "Me interesa / Suena bien",
     "go": 11
    },
    {
     "if": "¿Por qué no comprar en China?",
     "obj": 1,
     "go": 11
    },
    {
     "if": "¿Y la calidad? ¿Si llega dañado?",
     "obj": 2,
     "go": 11
    },
    {
     "if": "¿Con quién trabajan?",
     "obj": 7,
     "go": 11
    },
    {
     "if": "¿Pueden hacer mi diseño o mi marca?",
     "obj": 10,
     "go": 11
    }
   ]
  },
  {
   "n": 11,
   "title": "Precio y condiciones",
   "say": [
    "Le doy los números para que tenga una idea.",
    "Un tráiler completo entregado en CDMX, Monterrey o Guadalajara anda en unos 450,000 pesos, mercancía y flete juntos.",
    "Para empezar, el primer pedido puede ser desde unos 175,000 pesos, con mínimo 20 piezas por modelo.",
    "Las condiciones son 30 % de anticipo y 70 % al embarque, o carta de crédito. El precio de cada pieza depende de los modelos que elija; con su selección le mando la cotización."
   ],
   "branches": [
    {
     "if": "Está bien / Tiene sentido",
     "go": 12
    },
    {
     "if": "Está caro",
     "obj": 0,
     "go": 12
    },
    {
     "if": "¿Y el flete? ¿Quién paga el envío?",
     "obj": 3,
     "go": 12
    },
    {
     "if": "El mínimo es mucho",
     "obj": 5,
     "go": 12
    },
    {
     "if": "¿Me dan crédito a 30 o 60 días?",
     "obj": 6,
     "go": 12
    },
    {
     "if": "¿Cuánto tardan?",
     "obj": 11,
     "go": 12
    }
   ]
  },
  {
   "n": 12,
   "title": "Cierre: muestras o visita",
   "say": [
    "Lo más rápido para que vea la calidad es una de dos: le mandamos muestras de las piezas que elija, o viene a conocer la planta en Chipilo. ¿Qué le acomoda más?"
   ],
   "branches": [
    {
     "if": "Muestras",
     "go": 13
    },
    {
     "if": "Visita a la planta",
     "go": 14
    },
    {
     "if": "¿Las muestras son gratis?",
     "obj": 4,
     "say": "Entonces, ¿muestras o visita?",
     "go": 12
    },
    {
     "if": "Mándame el catálogo y yo te busco",
     "obj": 9,
     "note": "Pide la fecha para revisarlo. Si acepta fecha, ve al 15. Si no, una sola vez más: ¿muestras o visita?",
     "go": 15
    },
    {
     "if": "Lo tengo que platicar con alguien",
     "say": "Claro. ¿Le parece si hacemos la visita a la planta con esa persona? Así lo ven juntos. ¿Qué día les acomoda?",
     "go": 14
    }
   ]
  },
  {
   "n": 13,
   "title": "Muestras",
   "say": [
    "Perfecto. ¿Qué piezas le gustaría ver?",
    "Hoy le mando la cotización de esas muestras. Se pagan por adelantado y están listas en 30 días.",
    "¿A qué dirección se las enviamos, y a quién le llegan?"
   ],
   "branches": [
    {
     "if": "Te da piezas y dirección",
     "go": 15
    }
   ]
  },
  {
   "n": 14,
   "title": "Visita a Chipilo",
   "say": [
    "Excelente. ¿Qué día de la próxima semana o la siguiente le acomoda venir a Chipilo?",
    "¿Vendría usted solo o con alguien más de su equipo? Yo los acompaño en la planta."
   ],
   "branches": [
    {
     "if": "Te da fecha",
     "note": "Anota fecha, hora y quiénes vienen.",
     "go": 15
    }
   ]
  },
  {
   "n": 15,
   "title": "Antes de colgar",
   "say": [
    "Entonces quedamos en esto: (repite el siguiente paso, la fecha y quién hace qué).",
    "Hoy le escribo por correo y por WhatsApp con el resumen. Mi WhatsApp es el 222 437 4378. ¿A qué correo se lo mando, y quién más debe recibirlo?",
    "Muchas gracias, {contacto}. Que tenga muy buen día."
   ],
   "branches": [
    {
     "if": "Fin de la llamada",
     "note": "Manda el resumen el mismo día.",
     "go": null
    }
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

