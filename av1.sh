#!/bin/bash
# add_thumbnail.sh
# Antepone una imagen tuya (usada como miniatura) al principio de un video,
# sin recodificar el video original -> el peso final apenas aumenta.
#
# USO:
#   ./add_thumbnail.sh video.mp4 miniatura.jpg [duracion_segundos]
#
# Requiere: ffmpeg, ffprobe y mkvmerge (mkvtoolnix)
#   brew install ffmpeg mkvtoolnix        (macOS)
#   sudo apt install ffmpeg mkvtoolnix    (Linux)

set -e

VIDEO="$1"
IMAGE="$2"
DURATION="${3:-1.5}"

if [[ -z "$VIDEO" || -z "$IMAGE" ]]; then
  echo "Uso: $0 video.mp4 miniatura.jpg [duracion_en_segundos]"
  echo "Ejemplo: $0 vacaciones.mp4 caratula.png 1.5"
  exit 1
fi

if [[ ! -f "$VIDEO" ]]; then
  echo "Error: no encuentro el video '$VIDEO'"
  exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
  echo "Error: no encuentro la imagen '$IMAGE'"
  exit 1
fi

if ! command -v mkvmerge >/dev/null 2>&1; then
  echo "Error: necesitas mkvmerge instalado (paquete mkvtoolnix)."
  echo "  macOS: brew install mkvtoolnix"
  echo "  Linux: sudo apt install mkvtoolnix"
  exit 1
fi

BASENAME="${VIDEO%.*}"
EXT="${VIDEO##*.}"
INTRO="${BASENAME}_intro.mkv"
TEMP_MKV="${BASENAME}_temp.mkv"
OUTPUT="${BASENAME}_miniatura.${EXT}"

echo "== Analizando '$VIDEO' =="
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$VIDEO")
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$VIDEO")
FPS_RAW=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$VIDEO")
VCODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$VIDEO")
PIXFMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$VIDEO")
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$VIDEO" || true)
ASAMPLERATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$VIDEO" || echo "44100")
ACHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$VIDEO" || echo "2")

FPS=$(python3 -c "print(eval('$FPS_RAW'))" 2>/dev/null || echo "30")
[[ "$ACHANNELS" == "1" ]] && ACHLAYOUT="mono" || ACHLAYOUT="stereo"

echo "  Resolucion: ${WIDTH}x${HEIGHT}  FPS: ${FPS}  Codec video: ${VCODEC}"
echo "  Audio: ${HAS_AUDIO:-ninguno}  ${ASAMPLERATE}Hz  ${ACHANNELS}ch"

case "$VCODEC" in
  h264) VENC="libx264" ;;
  hevc) VENC="libx265" ;;
  vp9)  VENC="libvpx-vp9" ;;
  vp8)  VENC="libvpx" ;;
  av1)  VENC="libaom-av1" ;;
  *)    VENC="libx264"; echo "  Aviso: codec '$VCODEC' no reconocido, usando libx264 (revisa el resultado)";;
esac

case "$HAS_AUDIO" in
  opus)   AENC="libopus" ;;
  vorbis) AENC="libvorbis" ;;
  *)      AENC="aac" ;;
esac

SCALE_FILTER="scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black"

echo "== Generando clip introductorio de ${DURATION}s a partir de tu imagen =="
if [[ -n "$HAS_AUDIO" ]]; then
  ffmpeg -y -v error -loop 1 -i "$IMAGE" \
    -f lavfi -i "anullsrc=r=${ASAMPLERATE}:cl=${ACHLAYOUT}" \
    -t "$DURATION" -r "$FPS" -vf "$SCALE_FILTER" \
    -c:v "$VENC" -pix_fmt "$PIXFMT" -crf 18 \
    -c:a "$AENC" -ar "$ASAMPLERATE" -ac "$ACHANNELS" -b:a 128k -shortest "$INTRO"
else
  ffmpeg -y -v error -loop 1 -i "$IMAGE" \
    -t "$DURATION" -r "$FPS" -vf "$SCALE_FILTER" \
    -c:v "$VENC" -pix_fmt "$PIXFMT" -crf 18 \
    "$INTRO"
fi

echo "== Uniendo miniatura + video original con mkvmerge (recalcula bien los timestamps) =="
mkvmerge -q -o "$TEMP_MKV" "$INTRO" + "$VIDEO"

echo "== Recontainerizando a .${EXT} (remux de un solo archivo, sin recodificar) =="
if ffmpeg -y -v error -i "$TEMP_MKV" -c copy "$OUTPUT" 2>/tmp/remux_err.log; then
  rm -f "$TEMP_MKV"
else
  echo "  Aviso: el contenedor .${EXT} no admite este codec directamente."
  OUTPUT="${BASENAME}_miniatura.mkv"
  mv "$TEMP_MKV" "$OUTPUT"
  echo "  Se ha guardado como .mkv en su lugar: $OUTPUT"
fi

rm -f "$INTRO"
echo "== Listo: $OUTPUT =="
