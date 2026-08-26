"""Montaje final: ajusta cada escena a la locución y exporta el MP4 vertical.

Cada escena puede venir de un clip de video de stock (Pexels) o de una imagen
fija generada por IA (Nano Banana), animada con un efecto Ken Burns
(zoom/pan) para que no se vea estática.
"""

import os

import numpy as np
from PIL import Image
from moviepy import AudioFileClip, VideoClip, VideoFileClip, concatenate_videoclips

TARGET_W = 1080
TARGET_H = 1920
KEN_BURNS_ZOOM = 0.12  # cuánto crece la imagen a lo largo de la escena (12%)


def _fit_vertical(clip: VideoFileClip, w: int = TARGET_W, h: int = TARGET_H) -> VideoFileClip:
    """Escala el clip para cubrir el encuadre 9:16 y recorta el sobrante centrado."""
    scale = max(w / clip.w, h / clip.h)
    resized = clip.resized(scale)
    x_center, y_center = resized.w / 2, resized.h / 2
    return resized.cropped(
        x_center=x_center, y_center=y_center, width=w, height=h
    )


def _match_duration(clip: VideoFileClip, duration: float) -> VideoFileClip:
    """Recorta el clip a `duration`, o lo repite en loop si es más corto que el audio."""
    if clip.duration >= duration:
        return clip.subclipped(0, duration)

    loops_needed = int(duration // clip.duration) + 1
    looped = concatenate_videoclips([clip] * loops_needed)
    return looped.subclipped(0, duration)


def build_scene_clip_from_video(video_path: str, audio_path: str) -> VideoFileClip:
    audio = AudioFileClip(audio_path)
    video = VideoFileClip(video_path).without_audio()
    video = _fit_vertical(video)
    video = _match_duration(video, audio.duration)
    return video.with_duration(audio.duration).with_audio(audio)


def build_scene_clip_from_image(
    image_path: str, audio_path: str, w: int = TARGET_W, h: int = TARGET_H
) -> VideoClip:
    """Anima una imagen fija con un zoom lento (Ken Burns) durante toda la
    locución, recortada y centrada al encuadre 9:16."""
    audio = AudioFileClip(audio_path)
    duration = audio.duration

    pil_img = Image.open(image_path).convert("RGB")
    img_w, img_h = pil_img.size
    cover_scale = max(w / img_w, h / img_h)

    def make_frame(t):
        progress = min(t / duration, 1.0) if duration > 0 else 0.0
        scale = cover_scale * (1.0 + KEN_BURNS_ZOOM * progress)
        new_w = max(w, round(img_w * scale))
        new_h = max(h, round(img_h * scale))
        resized = pil_img.resize((new_w, new_h), Image.Resampling.LANCZOS)
        x1 = (new_w - w) // 2
        y1 = (new_h - h) // 2
        return np.array(resized.crop((x1, y1, x1 + w, y1 + h)))

    video = VideoClip(make_frame, duration=duration)
    return video.with_audio(audio)


def assemble_video(scenes: list[dict], output_path: str) -> str:
    """scenes: lista ordenada de escenas, cada una con "audio" y, o bien
    "video" (clip de stock) o "image" (imagen generada por IA)."""
    if not scenes:
        raise ValueError("No hay escenas para ensamblar.")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    clips = []
    for scene in scenes:
        if scene.get("image"):
            clips.append(build_scene_clip_from_image(scene["image"], scene["audio"]))
        elif scene.get("video"):
            clips.append(build_scene_clip_from_video(scene["video"], scene["audio"]))
        else:
            raise ValueError(f"Escena sin 'video' ni 'image': {scene}")

    final = concatenate_videoclips(clips, method="compose")

    final.write_videofile(
        output_path,
        fps=30,
        codec="libx264",
        audio_codec="aac",
        threads=4,
        logger=None,
    )

    for clip in clips:
        clip.close()
    final.close()

    return output_path
