"""Generador de videos cortos verticales (TikTok/Reels) a partir de un tema.

Pipeline: Gemini (guion) -> edge-tts (locución) -> Pexels (clips) -> MoviePy (montaje).
Ejecutar con: streamlit run app.py
"""

import os
import shutil
import tempfile

import streamlit as st
from dotenv import load_dotenv

from assemble import assemble_video
from script_gen import ScriptGenError, generate_script
from tts import VOICES, TTSError, synthesize_narration
from visuals import VisualsError, fetch_scene_clip

load_dotenv()

st.set_page_config(page_title="Generador de Video IA", page_icon="🎬", layout="centered")
st.title("🎬 Generador de Videos Cortos con IA")
st.caption("Guion (Gemini) → Locución (edge-tts) → Clips (Pexels) → Montaje (MoviePy)")

gemini_key_env = os.getenv("GEMINI_API_KEY", "")
pexels_key_env = os.getenv("PEXELS_API_KEY", "")

with st.sidebar:
    st.subheader("Claves API")
    gemini_key = st.text_input("GEMINI_API_KEY", value=gemini_key_env, type="password")
    pexels_key = st.text_input("PEXELS_API_KEY", value=pexels_key_env, type="password")
    st.caption("Se pueden dejar fijas en un archivo .env (ver README.md).")

topic = st.text_area(
    "¿De qué trata el video?",
    placeholder="Ej: 3 datos curiosos sobre el espacio",
    height=100,
)

col1, col2 = st.columns(2)
with col1:
    language = st.selectbox("Idioma / voz", list(VOICES.keys()))
with col2:
    gender = st.selectbox("Tipo de voz", ["Femenina", "Masculina"])

generate_clicked = st.button("🚀 Generar Video", type="primary", use_container_width=True)

if generate_clicked:
    if not topic.strip():
        st.error("Escribe primero de qué trata el video.")
    elif not gemini_key:
        st.error("Falta la GEMINI_API_KEY (ingrésala en la barra lateral o en .env).")
    elif not pexels_key:
        st.error("Falta la PEXELS_API_KEY (ingrésala en la barra lateral o en .env).")
    else:
        work_dir = tempfile.mkdtemp(prefix="videogen_")
        try:
            with st.status("Generando guion con Gemini...", expanded=True) as status:
                try:
                    scenes = generate_script(topic, language, gemini_key)
                except ScriptGenError as exc:
                    status.update(label="Error generando el guion", state="error")
                    st.error(str(exc))
                    st.stop()

                st.write(f"Guion listo: {len(scenes)} escenas.")
                for i, scene in enumerate(scenes, 1):
                    st.write(f"**Escena {i}:** {scene['narracion']}  \n_búsqueda: {scene['busqueda']}_")

                status.update(label="Generando locución y descargando clips...")
                scene_paths = []
                for i, scene in enumerate(scenes, 1):
                    st.write(f"Procesando escena {i}/{len(scenes)}...")

                    audio_path = os.path.join(work_dir, f"scene_{i}.mp3")
                    try:
                        synthesize_narration(scene["narracion"], language, gender, audio_path)
                    except TTSError as exc:
                        status.update(label="Error generando audio", state="error")
                        st.error(str(exc))
                        st.stop()

                    video_path = os.path.join(work_dir, f"scene_{i}.mp4")
                    try:
                        fetch_scene_clip(scene["busqueda"], pexels_key, video_path)
                    except VisualsError as exc:
                        status.update(label="Error descargando video de Pexels", state="error")
                        st.error(str(exc))
                        st.stop()

                    scene_paths.append({"video": video_path, "audio": audio_path})

                status.update(label="Ensamblando video final...")
                output_path = os.path.join(work_dir, "video_final.mp4")
                assemble_video(scene_paths, output_path)

                final_path = os.path.join(os.path.dirname(__file__), "output", "video_final.mp4")
                os.makedirs(os.path.dirname(final_path), exist_ok=True)
                shutil.copy(output_path, final_path)

                status.update(label="¡Video listo!", state="complete")

            st.success("Video generado correctamente.")
            st.video(final_path)
            with open(final_path, "rb") as f:
                st.download_button(
                    "⬇️ Descargar video",
                    data=f,
                    file_name="video_final.mp4",
                    mime="video/mp4",
                    use_container_width=True,
                )
        finally:
            shutil.rmtree(work_dir, ignore_errors=True)
