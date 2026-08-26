"""Generación del guion (escenas) a partir de un tema, usando la API de Gemini."""

import json
import re

import requests

GEMINI_MODEL = "gemini-3.6-flash"
GEMINI_URL = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
)


class ScriptGenError(RuntimeError):
    pass


def _extract_json(text: str):
    """Gemini a veces envuelve el JSON en ```json ... ```; lo limpiamos."""
    match = re.search(r"\[.*\]", text, re.DOTALL)
    if not match:
        raise ScriptGenError(f"No se encontró un arreglo JSON en la respuesta:\n{text}")
    return json.loads(match.group(0))


def generate_script(topic: str, language: str, api_key: str, num_scenes: str = "3 a 5") -> list[dict]:
    """Devuelve una lista de escenas: [{"narracion": str, "busqueda": str}, ...]

    - narracion: texto de locución en el idioma pedido.
    - busqueda: 2-4 palabras clave EN INGLÉS para buscar video de stock en Pexels
      (Pexels da mejores resultados con términos en inglés, sin importar el
      idioma de la narración).
    """
    prompt = f"""Eres un guionista de videos cortos verticales (TikTok/Reels).

Tema del video: "{topic}"
Idioma de la locución: {language}

Divide la historia/explicación en {num_scenes} escenas. Para cada escena entrega:
- "narracion": el texto que se leerá en voz alta (breve, natural, ÍNTEGRAMENTE en {language},
  sin mezclar palabras ni caracteres de otros idiomas o alfabetos).
- "busqueda": 2 a 4 palabras clave EN INGLÉS que describan visualmente la escena,
  útiles para buscar un video de stock (ej: "city traffic night", "coffee cup steam").

Responde ÚNICAMENTE con un arreglo JSON válido, sin texto adicional ni markdown, con este formato exacto:
[
  {{"narracion": "...", "busqueda": "..."}},
  {{"narracion": "...", "busqueda": "..."}}
]
"""

    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.8,
            "response_mime_type": "application/json",
        },
    }

    resp = requests.post(
        GEMINI_URL,
        params={"key": api_key},
        json=body,
        timeout=60,
    )

    if resp.status_code != 200:
        raise ScriptGenError(f"Gemini devolvió error {resp.status_code}: {resp.text}")

    data = resp.json()
    try:
        text = data["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError) as exc:
        raise ScriptGenError(f"Respuesta de Gemini inesperada: {data}") from exc

    try:
        scenes = json.loads(text)
    except json.JSONDecodeError:
        scenes = _extract_json(text)

    if not isinstance(scenes, list) or not scenes:
        raise ScriptGenError(f"El guion generado no es una lista válida de escenas: {scenes}")

    for scene in scenes:
        if "narracion" not in scene or "busqueda" not in scene:
            raise ScriptGenError(f"Escena incompleta en el guion: {scene}")

    return scenes
