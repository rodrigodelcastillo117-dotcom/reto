"""Generador de videos cortos verticales (TikTok/Reels) a partir de un tema,
o en modo canal automático (guion + rotación de especie/premisa).

Modo Genérico: Gemini (guion) -> edge-tts (locución) -> Pexels (clips) -> MoviePy (montaje).
Modo Guardianes Salvajes TV: Gemini (guion con rotación) -> edge-tts (locución)
    -> Nano Banana (imágenes IA por escena) -> MoviePy (montaje con Ken Burns).

Ejecutar con: streamlit run app.py
"""

import os
import shutil
import tempfile

import streamlit as st
from dotenv import load_dotenv

import guardianes_salvajes as gs
from assemble import assemble_video
from images_ai import ImageGenError, generate_scene_image
from script_gen import ScriptGenError, generate_script
from tts import VOICES, TTSError, synthesize_narration
from visuals import VisualsError, fetch_scene_clip

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

work_dir = None

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
                with st.status("Eligiendo especie y premisa del día...", expanded=True) as status:
                    categoria, especie_es, especie_en = gs.pick_especie(historial)
                    premisa = gs.pick_premisa(historial)
                    st.write(f"**Especie:** {especie_es} ({categoria})  \n**Premisa:** {premisa['nombre']}")

                    status.update(label="Generando guion con Gemini...")
                    prompt = gs.build_prompt(categoria, especie_es, premisa, historial)
                    try:
                        raw_script = gs.generate_text(prompt, gemini_key, temperature=0.9)
                    except ScriptGenError as exc:
                        status.update(label="Error generando el guion", state="error")
                        st.error(str(exc))
                        st.stop()

                    scenes_raw = gs.parse_script(raw_script)
                    if not scenes_raw:
                        status.update(label="El guion generado no se pudo interpretar", state="error")
                        st.error(f"Respuesta de Gemini sin escenas reconocibles:\n\n{raw_script}")
                        st.stop()

                    n_palabras = gs.contar_palabras_narracion(scenes_raw)
                    st.write(f"Guion listo: {len(scenes_raw)} escenas, {n_palabras} palabras de narración.")
                    for i, sc in enumerate(scenes_raw, 1):
                        st.write(f"**Escena {i}:** {sc['narracion']}  \n_visual: {sc['visual']}_")

                    status.update(label="Generando título...")
                    try:
                        titulo = gs.generate_title(raw_script, especie_es, gemini_key)
                    except ScriptGenError as exc:
                        status.update(label="Error generando el título", state="error")
                        st.error(str(exc))
                        st.stop()
                    st.write(f"**Título:** {titulo}")

                    status.update(label="Generando locución e imágenes por escena...")
                    scene_paths = []
                    for i, sc in enumerate(scenes_raw, 1):
                        st.write(f"Procesando escena {i}/{len(scenes_raw)}...")

                        audio_path = os.path.join(work_dir, f"scene_{i}.mp3")
                        try:
                            synthesize_narration(
                                sc["narracion"], "Español (Latinoamérica neutro)", gender_gs, audio_path
                            )
                        except TTSError as exc:
                            status.update(label="Error generando audio", state="error")
                            st.error(str(exc))
                            st.stop()

                        image_path = os.path.join(work_dir, f"scene_{i}.jpg")
                        try:
                            generate_scene_image(sc["visual"], gemini_key, image_path)
                        except ImageGenError as exc:
                            status.update(label="Error generando imagen con Nano Banana", state="error")
                            st.error(str(exc))
                            st.stop()

                        scene_paths.append({"image": image_path, "audio": audio_path})

                    status.update(label="Ensamblando video final...")
                    output_path = os.path.join(work_dir, "video_final.mp4")
                    assemble_video(scene_paths, output_path)

                    final_path = os.path.join(os.path.dirname(__file__), "output", "video_final.mp4")
                    os.makedirs(os.path.dirname(final_path), exist_ok=True)
                    shutil.copy(output_path, final_path)

                    gs.save_historial_entry({
                        "titulo": titulo,
                        "especie": especie_es,
                        "categoria": categoria,
                        "premisa_id": premisa["id"],
                        "fecha": gs.iso_now(),
                    })

                    status.update(label="¡Video listo!", state="complete")

                st.success(f"Video generado: {titulo}")
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
