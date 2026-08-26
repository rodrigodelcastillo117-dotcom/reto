"""Pipeline reutilizable de generación de video, sin dependencia de Streamlit.

Pensado para ser llamado tanto por app.py (interfaz visual) como por
integraciones externas (p.ej. un orquestador/worker como Harvey) que
generan videos en segundo plano y solo necesitan la ruta del MP4 final.
"""

import os

import guardianes_salvajes as gs
from assemble import assemble_video
from images_ai import generate_scene_image
from script_gen import generate_script
from tts import synthesize_narration
from visuals import fetch_scene_clip


def _noop(_message: str) -> None:
    pass


def generate_generic_video(
    topic: str,
    language: str,
    gender: str,
    gemini_key: str,
    pexels_key: str,
    work_dir: str,
    output_path: str,
    on_progress=_noop,
) -> dict:
    """Modo Genérico: tema libre -> guion (Gemini) -> locución (edge-tts)
    -> clips de stock (Pexels) -> montaje (MoviePy). Devuelve {"path": str}."""
    on_progress("Generando guion con Gemini...")
    scenes = generate_script(topic, language, gemini_key)

    scene_paths = []
    for i, scene in enumerate(scenes, 1):
        on_progress(f"Procesando escena {i}/{len(scenes)}...")

        audio_path = os.path.join(work_dir, f"scene_{i}.mp3")
        synthesize_narration(scene["narracion"], language, gender, audio_path)

        video_path = os.path.join(work_dir, f"scene_{i}.mp4")
        fetch_scene_clip(scene["busqueda"], pexels_key, video_path)

        scene_paths.append({"video": video_path, "audio": audio_path})

    on_progress("Ensamblando video final...")
    assemble_video(scene_paths, output_path)

    return {"path": output_path, "escenas": len(scenes)}


def generate_guardianes_video(
    gemini_key: str,
    gender: str,
    work_dir: str,
    output_path: str,
    on_progress=_noop,
) -> dict:
    """Modo Guardianes Salvajes TV: rotación de especie/premisa -> guion
    (Gemini) -> locución (edge-tts) -> imagen IA por escena (Nano Banana)
    -> montaje con Ken Burns (MoviePy). Actualiza el historial de rotación.

    Devuelve {"path": str, "titulo": str, "especie": str, "categoria": str,
    "premisa": str, "palabras": int, "escenas": int}.
    """
    historial = gs.load_historial()

    on_progress("Eligiendo especie y premisa del día...")
    categoria, especie_es, especie_en = gs.pick_especie(historial)
    premisa = gs.pick_premisa(historial)

    on_progress(f"Generando guion ({especie_es} / {premisa['nombre']})...")
    prompt = gs.build_prompt(categoria, especie_es, premisa, historial)
    raw_script = gs.generate_text(prompt, gemini_key, temperature=0.9)

    scenes_raw = gs.parse_script(raw_script)
    if not scenes_raw:
        raise ValueError(f"El guion generado no se pudo interpretar:\n{raw_script}")

    on_progress("Generando título...")
    titulo = gs.generate_title(raw_script, especie_es, gemini_key)

    scene_paths = []
    for i, sc in enumerate(scenes_raw, 1):
        on_progress(f"Procesando escena {i}/{len(scenes_raw)}...")

        audio_path = os.path.join(work_dir, f"scene_{i}.mp3")
        synthesize_narration(sc["narracion"], "Español (Latinoamérica neutro)", gender, audio_path)

        image_path = os.path.join(work_dir, f"scene_{i}.jpg")
        generate_scene_image(sc["visual"], gemini_key, image_path)

        scene_paths.append({"image": image_path, "audio": audio_path})

    on_progress("Ensamblando video final...")
    assemble_video(scene_paths, output_path)

    gs.save_historial_entry({
        "titulo": titulo,
        "especie": especie_es,
        "categoria": categoria,
        "premisa_id": premisa["id"],
        "fecha": gs.iso_now(),
    })

    return {
        "path": output_path,
        "titulo": titulo,
        "especie": especie_es,
        "categoria": categoria,
        "premisa": premisa["nombre"],
        "palabras": gs.contar_palabras_narracion(scenes_raw),
        "escenas": len(scenes_raw),
    }
