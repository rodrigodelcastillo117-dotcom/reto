# Generador de Videos Cortos con IA

App local en Streamlit que genera videos verticales (TikTok/Reels/Shorts) a partir de un tema:

`Gemini (guion en escenas)` → `edge-tts (locución, gratis)` → `Pexels (clips de video, gratis)` → `MoviePy (montaje)`

No depende de Revid.ai ni de Viewmax: todas las piezas son gratuitas (Gemini y Pexels tienen niveles
gratuitos con límites generosos; edge-tts es gratis y no requiere clave).

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
├── app.py           # Interfaz Streamlit y orquestación del pipeline
├── script_gen.py    # Genera el guion en escenas vía Gemini
├── tts.py           # Locución con edge-tts (gratis, sin API key)
├── visuals.py        # Búsqueda y descarga de clips verticales en Pexels
├── assemble.py       # Montaje final con MoviePy (recorte, duración, export MP4 9:16)
├── requirements.txt
├── .env.example
└── output/           # Videos generados
```

## Notas y límites

- Los clips de video son metraje de stock de Pexels que coincide con palabras clave, no video
  generado por IA desde cero (eso sí requiere modelos de pago tipo Sora/Kling/Veo).
- El nivel gratuito de Gemini y Pexels tiene límites de uso por minuto/día; si generas muchos
  videos seguidos puedes toparte con un error 429 (espera un minuto y reintenta).
- Cada ejecución sobrescribe `output/video_final.mp4`; descarga o renombra el video si quieres
  conservar varias versiones.
