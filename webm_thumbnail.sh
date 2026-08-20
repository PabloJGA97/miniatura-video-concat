#!/bin/bash
# add_thumbnail.sh
# Antepone una imagen tuya (usada como miniatura) al principio de un video,
# sin recodificar el video original -> el peso final apenas aumenta.
#
# USO:
#   ./add_thumbnail.sh video.mp4 miniatura.jpg [duracion_segundos]
#
# Requiere: ffmpeg y ffprobe instalados (brew install ffmpeg / apt install ffmpeg)

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

BASENAME="${VIDEO%.*}"
EXT="${VIDEO##*.}"
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

# Segun el codec, usamos una ruta distinta:
# - h264/hevc (tipico MP4): pasamos por .ts, que es lo fiable para estos codecs.
# - vp9/vp8/av1 (tipico WebM/MKV): Matroska concatena bien de forma directa, no hace falta .ts.
case "$VCODEC" in
  h264) VENC="libx264"; MODE="ts"; BSF="h264_mp4toannexb" ;;
  hevc) VENC="libx265"; MODE="ts"; BSF="hevc_mp4toannexb" ;;
  vp9)  VENC="libvpx-vp9"; MODE="mkv" ;;
  vp8)  VENC="libvpx"; MODE="mkv" ;;
  av1)  VENC="libaom-av1"; MODE="mkv" ;;
  *)    VENC="libx264"; MODE="ts"; BSF="h264_mp4toannexb"
        echo "  Aviso: codec '$VCODEC' no reconocido, usando libx264/h264 (revisa el resultado)";;
esac

# Codec de audio a usar en la intro, igual que el original
case "$HAS_AUDIO" in
  opus)   AENC="libopus" ;;
  vorbis) AENC="libvorbis" ;;
  *)      AENC="aac" ;;
esac

SCALE_FILTER="scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black"

INTRO="${BASENAME}_intro.${EXT}"

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

if [[ "$MODE" == "ts" ]]; then
  echo "== Convirtiendo a .ts para una concatenacion fiable (sin recodificar) =="
  INTRO_TS="${BASENAME}_intro.ts"
  VIDEO_TS="${BASENAME}_video.ts"
  ffmpeg -y -v error -i "$INTRO" -c copy -bsf:v "$BSF" -f mpegts "$INTRO_TS"
  ffmpeg -y -v error -i "$VIDEO" -c copy -bsf:v "$BSF" -f mpegts "$VIDEO_TS"

  echo "== Uniendo miniatura + video original =="
  if [[ -n "$HAS_AUDIO" ]]; then
    ffmpeg -y -v error -i "concat:${INTRO_TS}|${VIDEO_TS}" -c copy -bsf:a aac_adtstoasc "$OUTPUT"
  else
    ffmpeg -y -v error -i "concat:${INTRO_TS}|${VIDEO_TS}" -c copy "$OUTPUT"
  fi
  rm -f "$INTRO_TS" "$VIDEO_TS"
else
  echo "== Uniendo miniatura + video original (concat demuxer, Matroska/WebM) =="
  LIST="${BASENAME}_list.txt"
  printf "file '%s'\nfile '%s'\n" "$(basename "$INTRO")" "$(basename "$VIDEO")" > "$LIST"
  ffmpeg -y -v error -f concat -safe 0 -i "$LIST" -c copy "$OUTPUT"
  rm -f "$LIST"
fi

echo "== Listo: $OUTPUT =="
rm -f "$INTRO"
