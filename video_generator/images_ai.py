"""Generación de imágenes por escena con Nano Banana (Gemini image models),
para escenas narrativamente específicas donde no existe metraje de stock real."""

import base64
import os

import requests

IMAGE_MODEL = "gemini-3.1-flash-image"
IMAGE_URL = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{IMAGE_MODEL}:generateContent"
)

STYLE_SUFFIX = (
    ", cinematic wildlife documentary photography, photorealistic, natural warm light, "
    "shallow depth of field, no text, no watermark, no logo"
)


class ImageGenError(RuntimeError):
    pass


def generate_scene_image(visual_prompt: str, api_key: str, out_path: str) -> str:
    """Genera una imagen 9:16 a partir de la indicación visual de la escena
    y la guarda en `out_path`. Devuelve la ruta del archivo."""
    body = {
        "contents": [{"parts": [{"text": visual_prompt + STYLE_SUFFIX}]}],
        "generationConfig": {
            "responseModalities": ["IMAGE"],
            "imageConfig": {"aspectRatio": "9:16"},
        },
    }

    resp = requests.post(
        IMAGE_URL,
        headers={"x-goog-api-key": api_key, "Content-Type": "application/json"},
        json=body,
        timeout=90,
    )

    if resp.status_code != 200:
        raise ImageGenError(f"Nano Banana devolvió error {resp.status_code}: {resp.text}")

    data = resp.json()
    try:
        parts = data["candidates"][0]["content"]["parts"]
    except (KeyError, IndexError) as exc:
        raise ImageGenError(f"Respuesta de Nano Banana inesperada: {data}") from exc

    for part in parts:
        inline = part.get("inlineData") or part.get("inline_data")
        if inline and inline.get("data"):
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            with open(out_path, "wb") as f:
                f.write(base64.b64decode(inline["data"]))
            return out_path

    raise ImageGenError(f"Nano Banana no devolvió ninguna imagen para: {visual_prompt[:80]!r}")
