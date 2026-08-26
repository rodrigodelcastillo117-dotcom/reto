# Generador de Videos Cortos con IA

App local en Streamlit que genera videos verticales (TikTok/Reels/Shorts) a partir de un tema.
No depende de Revid.ai ni de Viewmax. Tiene dos modos:

- **Genérico** (tú eliges el tema): `Gemini (guion en escenas)` → `edge-tts (locución, gratis)` →
  `Pexels (clips de video de stock, gratis)` → `MoviePy (montaje)`
- **🦁 Guardianes Salvajes TV** (automático, con rotación de especie/premisa): `Gemini (guion)` →
  `edge-tts (locución, gratis)` → `Nano Banana (imagen IA por escena, de pago)` →
  `MoviePy (montaje con efecto Ken Burns)`

El modo Guardianes Salvajes usa imágenes generadas por IA en vez de metraje de stock porque sus
escenas son narrativamente muy específicas (p.ej. "una suricata cediendo su refugio a otra al
atardecer") y Pexels casi nunca tiene un clip real que coincida — solo trae animales genéricos que
no cuentan la historia. Cada imagen se anima con un zoom lento (Ken Burns) para que no se vea
estática. A diferencia del resto del pipeline, Nano Banana **no es gratis** (ver sección de costos).

## 1. Requisitos previos

### Claves API (gratis)

- **Gemini**: entra a [Google AI Studio](https://aistudio.google.com/apikey) con tu cuenta de Google
  y crea una API key. Es gratis dentro del nivel gratuito.
- **Pexels**: crea una cuenta en [pexels.com/api](https://www.pexels.com/api/) y genera tu API key
  gratuita (se aprueba al instante).

Copia `.env.example` a `.env` y pega tus claves:

```bash
cp .env.example .env
# edita .env y reemplaza los valores
```

(También puedes pegarlas directamente en la barra lateral de la app si prefieres no usar `.env`.)

### FFmpeg (motor de procesamiento de video)

MoviePy necesita `ffmpeg` instalado en el sistema.

**Windows:**
1. Descarga el build "release full" desde https://www.gyan.dev/ffmpeg/builds/ (sección "release builds").
2. Descomprime el .zip, por ejemplo en `C:\ffmpeg`.
3. Agrega `C:\ffmpeg\bin` a la variable de entorno `PATH` (Panel de control → Sistema → Configuración
   avanzada → Variables de entorno → Path → Nuevo).
4. Abre una terminal nueva y confirma con `ffmpeg -version`.

*Alternativa rápida con [Chocolatey](https://chocolatey.org/):* `choco install ffmpeg`

**macOS (con [Homebrew](https://brew.sh/)):**
```bash
brew install ffmpeg
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt update && sudo apt install -y ffmpeg
```

Verifica en cualquier sistema con:
```bash
ffmpeg -version
```

## 2. Instalación del proyecto

```bash
cd video_generator
python3 -m venv venv
source venv/bin/activate        # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

## 3. Ejecutar la app

```bash
streamlit run app.py
```

Se abrirá en tu navegador (normalmente `http://localhost:8501`). Escribe el tema del video, elige
idioma y voz, y presiona **Generar Video**. El resultado se muestra en pantalla y queda guardado en
`output/video_final.mp4`, además de poder descargarse con el botón.

## Estructura del proyecto

```
video_generator/
├── app.py                  # Interfaz Streamlit: selector de modo y orquestación del pipeline
├── script_gen.py           # Llamadas a Gemini (texto libre y guion en JSON)
├── guardianes_salvajes.py  # Prompt del canal, rotación de especie/premisa, parser, historial
├── images_ai.py            # Genera la imagen de cada escena con Nano Banana
├── tts.py                  # Locución con edge-tts (gratis, sin API key)
├── visuals.py               # Búsqueda y descarga de clips verticales en Pexels (modo Genérico)
├── assemble.py              # Montaje final con MoviePy (clip de stock o imagen + Ken Burns)
├── requirements.txt
├── .env.example
├── data/                    # historial_guardianes.json (rotación; no se sube a git)
└── output/                  # Videos generados
```

## Costos de Nano Banana (modo Guardianes Salvajes)

A diferencia del resto del pipeline, la generación de imágenes con `gemini-3.1-flash-image`
("Nano Banana 2") es de pago y requiere facturación activada en tu proyecto de Google AI
Studio/Cloud (no hay nivel gratuito para este modelo). Precio: **$0.067 por imagen** en 1K
(la resolución que usa la app). Un guion típico de este canal (28-32s) sale en 5-7 escenas, es
decir **≈ $0.35 a $0.47 por video**. Generando 1 video/día, 5 días a la semana: **≈ $10/mes**.

Para bajar el costo, en `images_ai.py` puedes cambiar `IMAGE_MODEL` a `"gemini-3.1-flash-lite-image"`
($0.0336/imagen, calidad algo menor).

## Notas y límites

- En el modo Genérico, los clips son metraje de stock de Pexels que coincide con palabras clave, no
  video generado por IA. En el modo Guardianes Salvajes, las imágenes sí son generadas por IA, pero
  siguen siendo imágenes fijas animadas con zoom (Ken Burns), no video con movimiento real del animal.
- El nivel gratuito de Gemini (texto) y Pexels tiene límites de uso por minuto/día; si generas muchos
  videos seguidos puedes toparte con un error 429 (espera un minuto y reintenta).
- Cada ejecución sobrescribe `output/video_final.mp4`; descarga o renombra el video si quieres
  conservar varias versiones.
- El historial de rotación vive en `data/historial_guardianes.json`. Si lo borras, la app vuelve a
  empezar la rotación desde cero (sin "últimos títulos" que evitar repetir).
