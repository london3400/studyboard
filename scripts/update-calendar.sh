#!/usr/bin/env bash
# Downloads the school's test calendar (provkalender) and this + next week's lunch menu
# into calendar-data.js, which the Studyboard page reads.
# Runs automatically on GitHub a few times a day (see .github/workflows/publish.yml).
# If a download fails, the last good copy is kept.
set -u

PROV_URL="https://karlstadskommunonline.sharepoint.com/:x:/s/GVFProvkalender/IQB1toSGoLb4QaA_6vxhUkzcASG7e-Zt9eQwZpb6AJnXWxU"
MENU_ID="68adaae3d6b9549ac0a3f3e1"   # Sundsta-Älvkullegymnasiet on Matilda

cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
now=$(( $(date +%s) * 1000 ))

# The last good data (if any), so a failed download never wipes it
echo '{}' > "$tmp/old.json"
if [ -f calendar-data.js ]; then
  sed -e 's/^window\.STUDYBOARD_DATA=//' -e 's/;[[:space:]]*$//' calendar-data.js > "$tmp/try.json"
  if jq -e 'type=="object"' "$tmp/try.json" > /dev/null 2>&1; then cp "$tmp/try.json" "$tmp/old.json"; fi
fi

# 1) Test calendar (Excel file on SharePoint). SharePoint hands out cookies while redirecting, so keep a cookie jar.
prov_ok=0
: > "$tmp/prov.b64"
if curl -fsSL --max-time 90 -c "$tmp/jar" -b "$tmp/jar" -A "Studyboard/1.0" -o "$tmp/prov.xlsx" "${PROV_URL%%\?*}?download=1" \
   && [ "$(head -c 2 "$tmp/prov.xlsx")" = "PK" ]; then
  base64 -w0 "$tmp/prov.xlsx" > "$tmp/prov.b64"
  prov_ok=1
  echo "Test calendar: OK"
else
  echo "Test calendar: download failed, keeping the last copy"
fi

# 2) Lunch menu: Monday this week to Sunday next week (Swedish time)
menu_ok=0
: > "$tmp/menu.json"
dow=$(date +%u)
monday=$(date -d "-$(( dow - 1 )) days" +%Y-%m-%d)
sunday=$(date -d "$monday +13 days" +%Y-%m-%d)
if curl -fsSL --max-time 60 -A "Studyboard/1.0" -o "$tmp/menu.json" \
   "https://menu.matildaplatform.com/api/menu?distributorId=${MENU_ID}&startDate=${monday}&endDate=${sunday}&lang=sv" \
   && jq -e '.meals' "$tmp/menu.json" > /dev/null 2>&1; then
  menu_ok=1
  echo "Lunch menu: OK ($monday to $sunday)"
else
  : > "$tmp/menu.json"
  echo "Lunch menu: download failed, keeping the last copy"
fi

jq -n \
  --argjson now "$now" --arg url "$PROV_URL" \
  --argjson prov_ok "$prov_ok" --argjson menu_ok "$menu_ok" \
  --rawfile b64 "$tmp/prov.b64" --rawfile menu "$tmp/menu.json" \
  --slurpfile old "$tmp/old.json" '
  ($old[0]) as $o
  | {fetchedAt: $now}
  + (if $prov_ok == 1 then {prov: {url: $url, fetchedAt: $now, base64: $b64}}
     elif ($o.prov.base64 // "") != "" then {prov: $o.prov}
     else {prov: {url: $url, error: "FETCH_FAILED"}} end)
  + (if $menu_ok == 1 then {menu: {fetchedAt: $now, json: $menu}}
     elif ($o.menu.json // "") != "" then {menu: $o.menu}
     else {menu: {error: "FETCH_FAILED"}} end)
  ' > "$tmp/data.json"

{ printf 'window.STUDYBOARD_DATA='; tr -d '\n' < "$tmp/data.json"; printf ';\n'; } > calendar-data.js
rm -rf "$tmp"
echo "calendar-data.js written ($(wc -c < calendar-data.js) bytes)"
