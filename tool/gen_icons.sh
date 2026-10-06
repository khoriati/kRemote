#!/usr/bin/env bash
# Gera os ícones do app (iOS + Android, incl. adaptativo) a partir de
# assets/icon/app_icon.svg e os tiles dos atalhos de apps em assets/apps.
#   tool/gen_icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "instale librsvg (brew install librsvg)"; exit 1; }
command -v magick >/dev/null || { echo "instale imagemagick (brew install imagemagick)"; exit 1; }

SRC=assets/icon/app_icon.svg
TMP="$(mktemp -d)"
rsvg-convert -w 1024 -h 1024 "$SRC" -o "$TMP/master.png"

# ---- iOS: um PNG por entrada do Contents.json (sem alpha) ----
IOS=ios/Runner/Assets.xcassets/AppIcon.appiconset
python3 - "$IOS/Contents.json" <<'PY' | while read -r file px; do
import json,sys
for i in json.load(open(sys.argv[1]))["images"]:
    size=float(i["size"].split("x")[0]); scale=int(i["scale"][0])
    print(i["filename"], int(round(size*scale)))
PY
  magick "$TMP/master.png" -resize "${px}x${px}" -background '#1B2A5B' -alpha remove -alpha off "$IOS/$file"
done

# ---- Android: legado (mipmap) + adaptativo (anydpi-v26) ----
RES=android/app/src/main/res
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  dpi="${d%%:*}"; px="${d##*:}"
  mkdir -p "$RES/mipmap-$dpi"
  # legado: cantos arredondados
  magick "$TMP/master.png" -resize "${px}x${px}" \
    \( +clone -alpha extract -draw "roundrectangle 0,0 $((px-1)),$((px-1)) $((px/5)),$((px/5))" -fill white -draw "roundrectangle 0,0 $((px-1)),$((px-1)) $((px/5)),$((px/5))" \) \
    -alpha off -compose CopyOpacity -composite "$RES/mipmap-$dpi/ic_launcher.png"
  # adaptativo: foreground em 108dp com a arte na zona segura (66%)
  fg=$((px*108/48)); inner=$((fg*66/100))
  magick "$TMP/master.png" -resize "${inner}x${inner}" -background none -gravity center -extent "${fg}x${fg}" "$RES/mipmap-$dpi/ic_launcher_foreground.png"
done
mkdir -p "$RES/mipmap-anydpi-v26" "$RES/values"
cat > "$RES/mipmap-anydpi-v26/ic_launcher.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XML
cat > "$RES/values/ic_launcher_background.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#1B2A5B</color>
</resources>
XML

# ---- Tiles dos atalhos de apps ----
if [[ -d assets/apps/src ]]; then
  for svg in assets/apps/src/*.svg; do
    name="$(basename "${svg%.svg}")"
    rsvg-convert -w 256 -h 256 "$svg" -o "assets/apps/$name.png"
  done
fi
rm -rf "$TMP"
echo "ícones gerados"
