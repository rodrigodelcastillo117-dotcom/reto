"""Búsqueda y descarga de clips de video verticales desde la API de Pexels."""

import os

import requests

PEXELS_SEARCH_URL = "https://api.pexels.com/videos/search"


class VisualsError(RuntimeError):
    pass


def _pick_best_video_file(video: dict) -> str | None:
    """De los archivos disponibles de un video de Pexels, elige uno vertical
    (portrait) en HD si existe; si no, el de mayor resolución disponible."""
    files = video.get("video_files", [])
    portrait = [f for f in files if f.get("height", 0) > f.get("width", 0)]
    candidates = portrait or files
    if not candidates:
        return None
    best = max(candidates, key=lambda f: f.get("height", 0) or 0)
    return best.get("link")


def search_vertical_video(query: str, api_key: str) -> dict | None:
    """Busca un video vertical en Pexels para la consulta dada.
    Devuelve {"url": str, "duration": float} o None si no hay resultados."""
    resp = requests.get(
        PEXELS_SEARCH_URL,
        headers={"Authorization": api_key},
        params={"query": query, "orientation": "portrait", "per_page": 5},
        timeout=30,
    )
    if resp.status_code != 200:
        raise VisualsError(f"Pexels devolvió error {resp.status_code}: {resp.text}")

    data = resp.json()
    videos = data.get("videos", [])
    if not videos:
        return None

    for video in videos:
        url = _pick_best_video_file(video)
        if url:
            return {"url": url, "duration": video.get("duration", 0)}

    return None


def download_video(url: str, out_path: str) -> str:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    resp = requests.get(url, stream=True, timeout=60)
    if resp.status_code != 200:
        raise VisualsError(f"No se pudo descargar el video ({resp.status_code}): {url}")

    with open(out_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=1 << 20):
            f.write(chunk)

    return out_path


def fetch_scene_clip(query: str, api_key: str, out_path: str) -> str:
    """Busca y descarga un clip vertical para la consulta dada. Si no hay
    resultados, reintenta con una consulta genérica de respaldo."""
    result = search_vertical_video(query, api_key)
    if not result:
        result = search_vertical_video("abstract background", api_key)
    if not result:
        raise VisualsError(f"No se encontraron videos en Pexels para: {query!r}")

    return download_video(result["url"], out_path)
