"""Locución (texto -> audio MP3) usando edge-tts, gratis y sin API key."""

import asyncio
import os

import edge_tts

# Voces recomendadas por idioma (femenina, masculina)
VOICES = {
    "Español (México)": {"Femenina": "es-MX-DaliaNeural", "Masculina": "es-MX-JorgeNeural"},
    "Español (España)": {"Femenina": "es-ES-ElviraNeural", "Masculina": "es-ES-AlvaroNeural"},
    "Español (Latinoamérica neutro)": {
        "Femenina": "es-US-PalomaNeural",
        "Masculina": "es-US-AlonsoNeural",
    },
    "Inglés (US)": {"Femenina": "en-US-AriaNeural", "Masculina": "en-US-GuyNeural"},
}


class TTSError(RuntimeError):
    pass


async def _synthesize(text: str, voice: str, out_path: str):
    communicate = edge_tts.Communicate(text, voice)
    await communicate.save(out_path)


def synthesize_narration(text: str, language: str, gender: str, out_path: str) -> str:
    """Genera un archivo MP3 con la locución. Devuelve la ruta del archivo."""
    voice = VOICES.get(language, VOICES["Español (México)"])[gender]

    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    try:
        asyncio.run(_synthesize(text, voice, out_path))
    except Exception as exc:  # edge-tts lanza varios tipos de error de red
        raise TTSError(f"Fallo generando audio con edge-tts (voz {voice}): {exc}") from exc

    if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
        raise TTSError(f"edge-tts no generó audio para: {text[:60]!r}")

    return out_path
