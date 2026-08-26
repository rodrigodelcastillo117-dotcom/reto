"""Montaje final: ajusta cada clip a la locución y exporta el MP4 vertical."""

import os

from moviepy import AudioFileClip, VideoFileClip, concatenate_videoclips

TARGET_W = 1080
TARGET_H = 1920


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


def build_scene_clip(video_path: str, audio_path: str) -> VideoFileClip:
    audio = AudioFileClip(audio_path)
    video = VideoFileClip(video_path).without_audio()
    video = _fit_vertical(video)
    video = _match_duration(video, audio.duration)
    return video.with_duration(audio.duration).with_audio(audio)


def assemble_video(scene_paths: list[dict], output_path: str) -> str:
    """scene_paths: [{"video": path, "audio": path}, ...] en orden de aparición."""
    if not scene_paths:
        raise ValueError("No hay escenas para ensamblar.")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    clips = [build_scene_clip(s["video"], s["audio"]) for s in scene_paths]
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
