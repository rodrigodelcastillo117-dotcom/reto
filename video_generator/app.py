"""Generador de videos cortos verticales (TikTok/Reels) a partir de un tema,
o en modo canal automático (guion + rotación de especie/premisa).

Modo Genérico: Gemini (guion) -> edge-tts (locución) -> Pexels (clips) -> MoviePy (montaje).
Modo Guardianes Salvajes TV: Gemini (guion con rotación) -> edge-tts (locución)
    -> Nano Banana (imágenes IA por escena) -> MoviePy (montaje con Ken Burns).

La lógica del pipeline vive en pipeline.py (sin dependencia de Streamlit), para
que también pueda llamarse desde otros sistemas (workers, dashboards, etc.).

Ejecutar con: streamlit run app.py
"""

import os
import shutil
import tempfile

import streamlit as st
from dotenv import load_dotenv

import guardianes_salvajes as gs
from pipeline import generate_generic_video, generate_guardianes_video
from script_gen import ScriptGenError
from tts import VOICES, TTSError
from visuals import VisualsError
from images_ai import ImageGenError

load_dotenv()

st.set_page_config(page_title="Generador de Video IA", page_icon="🎬", layout="centered")
st.title("🎬 Generador de Videos Cortos con IA")

gemini_key_env = os.getenv("GEMINI_API_KEY", "")
pexels_key_env = os.getenv("PEXELS_API_KEY", "")

with st.sidebar:
    st.subheader("Claves API")
    gemini_key = st.text_input("GEMINI_API_KEY", value=gemini_key_env, type="password")
    pexels_key = st.text_input(
        "PEXELS_API_KEY", value=pexels_key_env, type="password",
        help="Solo se usa en el modo Genérico.",
    )
    st.caption("Se pueden dejar fijas en un archivo .env (ver README.md).")

modo = st.radio(
    "Modo",
    ["Genérico (tú eliges el tema)", "🦁 Guardianes Salvajes TV (automático)"],
    horizontal=False,
)

FINAL_VIDEO_PATH = os.path.join(os.path.dirname(__file__), "output", "video_final.mp4")

# ─────────────────────────────────────────────────────────────
# MODO GENÉRICO
# ─────────────────────────────────────────────────────────────
if modo.startswith("Genérico"):
    st.caption("Guion (Gemini) → Locución (edge-tts) → Clips de stock (Pexels) → Montaje (MoviePy)")

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
                with st.status("Generando video...", expanded=True) as status:
                    try:
                        result = generate_generic_video(
                            topic, language, gender, gemini_key, pexels_key,
                            work_dir, FINAL_VIDEO_PATH, on_progress=lambda msg: st.write(msg),
                        )
                    except ScriptGenError as exc:
                        status.update(label="Error generando el guion", state="error")
                        st.error(str(exc))
                        st.stop()
                    except TTSError as exc:
                        status.update(label="Error generando audio", state="error")
                        st.error(str(exc))
                        st.stop()
                    except VisualsError as exc:
                        status.update(label="Error descargando video de Pexels", state="error")
                        st.error(str(exc))
                        st.stop()

                    status.update(label="¡Video listo!", state="complete")

                st.success(f"Video generado correctamente ({result['escenas']} escenas).")
                st.video(FINAL_VIDEO_PATH)
                with open(FINAL_VIDEO_PATH, "rb") as f:
                    st.download_button(
                        "⬇️ Descargar video",
                        data=f,
                        file_name="video_final.mp4",
                        mime="video/mp4",
                        use_container_width=True,
                    )
            finally:
                shutil.rmtree(work_dir, ignore_errors=True)

# ─────────────────────────────────────────────────────────────
# MODO GUARDIANES SALVAJES TV
# ─────────────────────────────────────────────────────────────
else:
    st.caption(
        "Guion (Gemini, rotación de especie/premisa) → Locución (edge-tts) "
        "→ Imágenes IA por escena (Nano Banana) → Montaje con Ken Burns (MoviePy)"
    )

    historial = gs.load_historial()
    st.write(f"Videos producidos hasta ahora: **{len(historial)}**")
    if historial:
        with st.expander("Ver historial reciente"):
            for h in historial[-10:][::-1]:
                st.write(f"- {h['titulo']}  ·  _{h['especie']} ({h['categoria']})_")

    gender_gs = st.selectbox("Tipo de voz", ["Femenina", "Masculina"], key="gender_gs")

    generate_gs_clicked = st.button(
        "🦁 Generar Video del Día", type="primary", use_container_width=True
    )

    if generate_gs_clicked:
        if not gemini_key:
            st.error("Falta la GEMINI_API_KEY (ingrésala en la barra lateral o en .env).")
        else:
            work_dir = tempfile.mkdtemp(prefix="videogen_gs_")
            try:
                with st.status("Generando video...", expanded=True) as status:
                    try:
                        result = generate_guardianes_video(
                            gemini_key, gender_gs, work_dir, FINAL_VIDEO_PATH,
                            on_progress=lambda msg: st.write(msg),
                        )
                    except ScriptGenError as exc:
                        status.update(label="Error generando el guion", state="error")
                        st.error(str(exc))
                        st.stop()
                    except TTSError as exc:
                        status.update(label="Error generando audio", state="error")
                        st.error(str(exc))
                        st.stop()
                    except ImageGenError as exc:
                        status.update(label="Error generando imagen con Nano Banana", state="error")
                        st.error(str(exc))
                        st.stop()
                    except ValueError as exc:
                        status.update(label="El guion generado no se pudo interpretar", state="error")
                        st.error(str(exc))
                        st.stop()

                    status.update(label="¡Video listo!", state="complete")

                st.success(f"Video generado: {result['titulo']}")
                st.caption(
                    f"Especie: {result['especie']} ({result['categoria']}) · "
                    f"Premisa: {result['premisa']} · {result['palabras']} palabras · "
                    f"{result['escenas']} escenas"
                )
                st.video(FINAL_VIDEO_PATH)
                with open(FINAL_VIDEO_PATH, "rb") as f:
                    st.download_button(
                        "⬇️ Descargar video",
                        data=f,
                        file_name="video_final.mp4",
                        mime="video/mp4",
                        use_container_width=True,
                    )
            finally:
                shutil.rmtree(work_dir, ignore_errors=True)
