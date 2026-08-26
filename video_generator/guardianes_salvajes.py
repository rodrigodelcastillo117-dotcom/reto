"""Modo de canal 'GUARDIANES SALVAJES TV': guion automático de hazañas animales
asombrosas, con rotación de especie/premisa y formato de salida en texto plano
(narración en español + indicaciones visuales en inglés entre corchetes),
siguiendo el prompt de producción del canal.
"""

import json
import os
import random
from datetime import datetime, timezone

from script_gen import generate_text

HISTORIAL_PATH = os.path.join(os.path.dirname(__file__), "data", "historial_guardianes.json")

# categoría -> {peso (de cada 10 videos), especies: {es: en}}
CATEGORIAS = {
    "mamiferos_comunes": {
        "peso": 3,
        "especies": {
            "perro": "dog",
            "gato": "cat",
            "conejo": "rabbit",
            "caballo": "horse",
            "burro": "donkey",
            "mula": "mule",
        },
    },
    "salvajes_terrestres": {
        "peso": 3,
        "especies": {
            "lobo": "wolf",
            "zorro": "fox",
            "mapache": "raccoon",
            "elefante": "elephant",
            "jirafa": "giraffe",
            "chimpancé": "chimpanzee",
            "orangután": "orangutan",
            "suricata": "meerkat",
            "castor": "beaver",
            "canguro": "kangaroo",
        },
    },
    "aves": {
        "peso": 2,
        "especies": {
            "cuervo": "crow",
            "urraca": "magpie",
            "loro": "parrot",
            "cacatúa": "cockatoo",
            "búho": "owl",
            "águila": "eagle",
        },
    },
    "marinos": {
        "peso": 1,
        "especies": {
            "pulpo": "octopus",
            "delfín": "dolphin",
            "nutria": "otter",
            "ballena": "whale",
            "foca": "seal",
            "tortuga": "turtle",
        },
    },
    "sorprendentes": {
        "peso": 1,
        "especies": {
            "abeja": "bee",
            "hormiga": "ant",
            "murciélago": "bat",
        },
    },
}

PREMISAS = [
    {
        "id": 1,
        "nombre": "Comportamiento humano inexplicable",
        "descripcion": (
            "El animal hace algo que solo hacen las personas: comprar, pagar, guardar, "
            "negociar, planear, devolver un favor. Ejemplos de referencia que NO debes "
            "repetir: el cuervo que compra flores, el mapache que lava y ordena monedas, "
            "el pulpo que abre frascos por dentro."
        ),
    },
    {
        "id": 2,
        "nombre": "Percepción imposible",
        "descripcion": (
            "El animal supo algo que ningún humano podía saber. Ejemplos de referencia "
            "que NO debes repetir: el caballo que predijo un derrumbe, el elefante que "
            "sintió el tsunami antes que los sensores, el perro que detecta convulsiones "
            "minutos antes."
        ),
    },
    {
        "id": 3,
        "nombre": "Relación sostenida entre especies",
        "descripcion": (
            "Un vínculo que duró meses o años, no un momento aislado. Ejemplos de "
            "referencia que NO debes repetir: el elefante y la viejita del jardín, la "
            "buza y el pulpo que la reconoció dos años después, el zorro que volvía cada "
            "invierno a la misma puerta."
        ),
    },
    {
        "id": 4,
        "nombre": "Decisión social o jerárquica",
        "descripcion": (
            "El animal ELIGIÓ algo; no reaccionó, decidió. Ejemplos de referencia que NO "
            "debes repetir: el lobo que eligió la casa, la leona que adoptó a la cría de "
            "su presa, el chimpancé que reparte comida solo con quien lo trató bien."
        ),
    },
    {
        "id": 5,
        "nombre": "Rescate atípico para la especie",
        "descripcion": (
            "Un rescate SOLO si el animal es inesperado para ese acto. Ejemplos de "
            "referencia que NO debes repetir: el loro que salvó a su vecina, el gato que "
            "despierta a la familia por una fuga de gas. Un delfín salvando a un humano "
            "NO sirve: es lo esperado de un delfín."
        ),
    },
]

_PROMPT_TEMPLATE = """Eres el guionista de GUARDIANES SALVAJES TV, canal en español latino neutro
sobre hazañas animales asombrosas. Escribes en modo SCRIPT.

FORMATO: video vertical 9:16. DURACIÓN OBJETIVO: 28-32 segundos.
Eso son 55 a 65 palabras de narración. No te pases.

Los datos del canal son claros: los videos de 27-30 segundos retienen 110%.
Los de 36-45 segundos retienen 103%. Los de más de 46 segundos retienen 84%.
La duración es la variable individual que más afecta la retención.

═══════════════════════════════════════════
REGLA DE VERACIDAD — LEE ESTO PRIMERO
═══════════════════════════════════════════
El video es una RECREACIÓN generada por IA de comportamiento animal real y
documentado. Nunca afirmes que un evento específico ocurrió en una fecha,
lugar o con personas concretas verificables.

SÍ: "Los cuervos reconocen rostros humanos hasta cinco años después."
NO: "En marzo de 2019, en Puebla, el cuervo de la familia Rojas..."

El comportamiento debe ser científicamente real. La historia es narrativa.
Nunca inventes nombres de personas reales, ONGs o instituciones existentes.
Prohibido cualquier poder inventado o ciencia ficción.

LA ESPECIFICIDAD VA EN EL COMPORTAMIENTO, NO EN EL EVENTO.
Lo específico gana en retención, pero lo específico tiene que ser el dato
científico sobre la especie, no un suceso fabricado.

SÍ: "Una urraca puede guardar y recuperar más de mil escondites."
NO: "Esta urraca dejó setenta y tres objetos entre 2019 y 2021."

═══════════════════════════════════════════
LA REGLA QUE DECIDE TODO
═══════════════════════════════════════════
El espectador no quiere ver a un animal salvando a una persona. Ya lo vio
mil veces y sabe cómo termina antes de que empiece.

Quiere ver a un animal haciendo algo que NADIE PUEDE EXPLICAR.

No es opinión, son los números del canal:
  "animal salva a alguien"        → 96% de retención
  "animal hizo algo inexplicable" → 104% de retención y más vistas

Si el desenlace se adivina desde el título, el espectador se va en el
segundo dos.

PREMISA DE HOY: {premisa}

═══════════════════════════════════════════
ESPECIE — YA ELEGIDA POR ROTACIÓN, NO LA CAMBIES
═══════════════════════════════════════════
ESPECIE DE HOY: {especie}

El video entero debe tratar sobre un(a) {especie}. Todas las indicaciones
visuales entre corchetes deben mostrar un(a) {especie}, nunca otro animal.

═══════════════════════════════════════════
HOOK — LOS PRIMEROS 2 SEGUNDOS
═══════════════════════════════════════════
Aquí se decide si el video vive o muere.

REGLA DURA: el primer plano visual muestra MOVIMIENTO o TENSIÓN antes de
que termine la primera frase hablada. Nunca abras con paisaje, logo ni
plano establecedor estático.

Primera frase hablada: MÁXIMO 8 PALABRAS. Debe caber en 2 segundos reales.

DÉBIL (11 palabras, ~4s, el scroll ya pasó):
"Este cuervo visitaba la misma ventana todos los días sin falta"
FUERTE (6 palabras, ~2s):
"Dejó un regalo. Luego otro."

Estructura: [primer plano del rostro o los ojos del animal, en movimiento
o en alerta] + frase de máximo 8 palabras que plantea el enigma.

═══════════════════════════════════════════
DESARROLLO — 30 SEGUNDOS, UN SOLO GIRO
═══════════════════════════════════════════
Una sola historia. Una sola línea narrativa.

En 30 segundos cabe UN micro-giro, no dos. Va entre el segundo 12 y el 15:
"Pero lo que hizo después nadie lo esperaba."

Frases cortas. Máximo 12 palabras por frase hablada.
El punto y seguido pega más fuerte que la coma.
Cada 3-4 segundos debe pasar algo nuevo en pantalla.

Reparto del tiempo:
  0-2s    el hook
  2-12s   la anomalía y el dato científico que la hace creíble
  12-15s  el micro-giro
  15-25s  el intento de explicación: hay teorías, ninguna cierra
  25-30s  cierre y loop

═══════════════════════════════════════════
CIERRE Y LOOP
═══════════════════════════════════════════
Los últimos 3 segundos conectan visualmente con el primer plano del video,
para que el loop se sienta continuo. Un rewatch cuenta como vista nueva y
es lo que pone la retención arriba de 100%.

NO RESUELVAS. Deja la pregunta viva.

Cierra con UNA de estas:
1. Dato científico real que resignifique todo lo visto
2. Frase corta y compartible
3. Una pregunta abierta

Nunca cierres con "suscríbete" hablado.

═══════════════════════════════════════════
RESTRICCIONES VISUALES — PROTECCIÓN DE POLÍTICAS
═══════════════════════════════════════════
Este canal recibió una advertencia por contenido violento o gráfico.
Estas reglas no son negociables:
- NUNCA mostrar el momento de un ataque, mordida o impacto. Corta antes,
  retoma después.
- NUNCA sangre, heridas abiertas, animales en agonía, cadáveres.
- El peligro se comunica por REACCIÓN, no por el evento: los ojos del
  animal, postura defensiva, huida, otros animales alertas.
- Si hay un depredador, se muestra acechando o alejándose. Nunca en
  contacto físico con otro animal.
- Escenas del "después" permitidas: animal a salvo, respirando, siendo
  atendido, reunido con su grupo.
- Tono: emotivo, fascinante, cálido. Nunca oscuro, nunca angustiante.

═══════════════════════════════════════════
INDICACIONES VISUALES
═══════════════════════════════════════════
Después de cada 1-2 frases, inserta una indicación entre corchetes:
[sujeto + acción + ambiente + ángulo + emoción]
Ejemplo: [Close-up of a crow's eyes, head tilted, staring directly at
camera, morning light, contained intelligence]
Estilo visual coherente en todo el video: cinematográfico, realista, luz
natural cálida, profundidad de campo. Sin saturación artificial.

═══════════════════════════════════════════
PROHIBIDOS POR SATURACIÓN
═══════════════════════════════════════════
- Perro salva niña de ahogarse
- Gato salva anciano
- Delfín salva surfista de tiburón
- Perro espera en la tumba del dueño
- Elefante salva a su cuidador
- "Volvió a buscar a quien lo salvó"
- Cualquier reencuentro genérico sin premisa inexplicable

YA PRODUCIDOS — NO REPITAS ESTAS IDEAS NI NADA PARECIDO:
{ultimos_titulos}

═══════════════════════════════════════════
META
═══════════════════════════════════════════
Que el espectador sienta: "esto es increíble, tengo que enseñárselo a
alguien". Ternura, asombro y emoción. Nunca morbo.

═══════════════════════════════════════════
FORMATO DE SALIDA
═══════════════════════════════════════════
Escribe ÚNICAMENTE el guion del video. Nada más.
Lo que escribas se convierte directamente en la narración y en los
subtítulos, así que:
- NO escribas JSON, ni llaves, ni comillas de campo
- NO escribas títulos, encabezados ni etiquetas de sección
- NO escribas explicaciones antes ni después
El video solo contiene la historia hablada.

Alterna líneas de narración en ESPAÑOL con indicaciones visuales en INGLÉS
entre corchetes.

Ejemplo del formato exacto:
Dejó un regalo. Luego otro.
[Close up of a magpie placing a small shiny object on a windowsill, morning light, sharp intelligent eye]
Tornillos. Aretes. Un botón de nácar.
[A windowsill with several small trinkets arranged in a row, soft daylight]
"""

_TITLE_PROMPT_TEMPLATE = """Basado en este guion sobre un(a) {especie}, escribe SOLO el título del video.

FÓRMULA GANADORA: "El/La {especie} que [verbo concreto] [complemento concreto]"
Enuncia el hecho concreto directamente, no lo escondas. Máximo 8 palabras.

FUERTE: El cuervo que compra flores
FUERTE: El loro que salvó a su vecina
FUERTE: El lobo que eligió la casa
DÉBIL:  Elefante hizo lo imposible por salvar niña

PROHIBIDO en el título:
- Vaguedades: "hizo lo imposible", "no vas a creer", "lo que pasó te va a sorprender", "mira hasta el final"
- Palabras: ataque, sangre, muerte, brutal, matar, herido, agonía
- Emojis, o más de un signo de admiración

Responde ÚNICAMENTE con el título, sin comillas ni explicación.

Guion:
{guion}
"""


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_historial() -> list[dict]:
    if not os.path.exists(HISTORIAL_PATH):
        return []
    with open(HISTORIAL_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def save_historial_entry(entry: dict) -> None:
    historial = load_historial()
    historial.append(entry)
    os.makedirs(os.path.dirname(HISTORIAL_PATH), exist_ok=True)
    with open(HISTORIAL_PATH, "w", encoding="utf-8") as f:
        json.dump(historial, f, ensure_ascii=False, indent=2)


def pick_especie(historial: list[dict]) -> tuple[str, str, str]:
    """Elige (categoria, especie_es, especie_en) respetando la rotación:
    no repetir la categoría del último video, y evitar aves si ya aparecieron
    2+ veces en los últimos 6 videos."""
    last_categoria = historial[-1]["categoria"] if historial else None
    ultimos_6 = historial[-6:]
    aves_recientes = sum(1 for h in ultimos_6 if h.get("categoria") == "aves")

    permitidas = {cat: datos for cat, datos in CATEGORIAS.items() if cat != last_categoria}
    if aves_recientes >= 2:
        permitidas.pop("aves", None)
    if not permitidas:
        permitidas = CATEGORIAS

    categorias = list(permitidas.keys())
    pesos = [permitidas[c]["peso"] for c in categorias]
    categoria = random.choices(categorias, weights=pesos, k=1)[0]

    especies = CATEGORIAS[categoria]["especies"]
    ultima_especie = historial[-1]["especie"] if historial else None
    candidatas = {es: en for es, en in especies.items() if es != ultima_especie} or especies
    especie_es = random.choice(list(candidatas.keys()))
    especie_en = especies[especie_es]

    return categoria, especie_es, especie_en


def pick_premisa(historial: list[dict]) -> dict:
    """Elige una premisa evitando repetir la del último video."""
    ultima_id = historial[-1]["premisa_id"] if historial else None
    candidatas = [p for p in PREMISAS if p["id"] != ultima_id] or PREMISAS
    return random.choice(candidatas)


def build_prompt(categoria: str, especie_es: str, premisa: dict, historial: list[dict]) -> str:
    ultimos_titulos = [h["titulo"] for h in historial[-20:]]
    bloque_titulos = (
        "\n".join(f"- {t}" for t in ultimos_titulos)
        if ultimos_titulos
        else "(Todavía no se ha producido ningún video en este canal.)"
    )
    return _PROMPT_TEMPLATE.format(
        premisa=f"{premisa['nombre']}. {premisa['descripcion']}",
        especie=especie_es,
        ultimos_titulos=bloque_titulos,
    )


def parse_script(raw_text: str) -> list[dict]:
    """Convierte el texto plano (narración / [indicación visual]) en escenas
    [{"narracion": str, "visual": str}, ...]."""
    lines = [l.strip() for l in raw_text.strip().splitlines() if l.strip()]
    scenes: list[dict] = []
    pending_narracion = None

    for line in lines:
        if line.startswith("[") and line.endswith("]"):
            visual = line[1:-1].strip()
            if pending_narracion is not None:
                scenes.append({"narracion": pending_narracion, "visual": visual})
                pending_narracion = None
            elif scenes:
                scenes[-1]["visual"] = (scenes[-1]["visual"] + " " + visual).strip()
        else:
            if pending_narracion is not None:
                scenes.append({"narracion": pending_narracion, "visual": ""})
            pending_narracion = line

    if pending_narracion is not None:
        scenes.append({"narracion": pending_narracion, "visual": ""})

    return scenes


def build_pexels_query(especie_en: str, visual_text: str, max_words: int = 6) -> str:
    if not visual_text:
        return f"{especie_en} wildlife closeup"
    short = " ".join(visual_text.split()[:max_words])
    if especie_en.lower() not in short.lower():
        short = f"{especie_en} {short}"
    return short


def generate_title(guion: str, especie_es: str, api_key: str) -> str:
    prompt = _TITLE_PROMPT_TEMPLATE.format(especie=especie_es, guion=guion)
    return generate_text(prompt, api_key, temperature=0.7).strip().strip('"')


def contar_palabras_narracion(scenes: list[dict]) -> int:
    return sum(len(s["narracion"].split()) for s in scenes)
