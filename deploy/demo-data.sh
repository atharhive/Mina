#!/usr/bin/env bash
# A synthetic scenario for the demonstration, posted through the public API: monsoon flooding in
# area 1, with reports around Mumbai and alerts in three languages. Every text is marked as
# synthetic. Safe to rerun: the event ids are fixed, so nothing is stored twice.
#
#   MINA_SECRET=... deploy/demo-data.sh [base url] [area]
#
# Needs bin/mina-admin (or MINA_ADMIN), curl and jq.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=${1:-http://127.0.0.1} AREA=${2:-1}
ADMIN=${MINA_ADMIN:-bin/mina-admin}
: "${MINA_SECRET:?}"
eid() { printf 'mina-demo %s %s' "$AREA" "$1" | sha256sum | cut -c1-32; }
post() {   # post <token> <name> <members of the event>
  curl -sS --fail-with-body -m 10 -H "authorization: Bearer $1" -d "{\"eid\":\"$(eid "$2")\",$3}" "$BASE/v1/events"
  echo
}
# one fixed synthetic citizen per report, so that a rerun repeats the same submissions
citizen() { "$ADMIN" token --sub "$((900000000000 + $1))" --role citizen --ttl 3600; }
responder=$("$ADMIN" token --sub 900000000900 --role responder --regions "$AREA" --ttl 3600)

n=0
report() {   # report <category> <lat> <lon> <text>
  n=$((n + 1))
  post "$(citizen $n)" "report $n" "\"kind\":1,\"region\":$AREA,\"category\":$1,\"lat\":$2,\"lon\":$3,\"body\":\"$4\""
}
report 2 1907600 7287700 "[synthetic] Water has reached the first floor, three people upstairs"
report 1 1908900 7289600 "[synthetic] बुज़ुर्ग को दवा चाहिए, रास्ता पानी में डूबा है"
report 3 1904100 7285800 "[synthetic] इमारतीला तडे गेले आहेत, बाहेर काढण्यासाठी मदत हवी"
report 5 1911200 7290900 "[synthetic] No drinking water since morning, about forty families"
report 4 1901800 7284100 "[synthetic] Shelter at the school is short of food for children"

alert() { post "$responder" "alert $1" "\"kind\":6,\"region\":$AREA,\"body\":\"$2\""; }
alert 1 "[synthetic] Heavy rain warning: move to upper floors and keep your phone charged"
alert 2 "[synthetic] भारी बारिश की चेतावनी: ऊपरी मंज़िल पर जाएँ और फ़ोन चार्ज रखें"
alert 3 "[synthetic] मुसळधार पावसाचा इशारा: वरच्या मजल्यावर जा आणि फोन चार्ज ठेवा"
