#!/bin/bash
#
# collect.sh — capture un instantané complet d'une JVM en un seul fichier JSON,
# en n'utilisant que les utilitaires du bin du JDK (jcmd, jstat) + bash/awk.
# Aucune dépendance externe (pas de jq).
#
# Usage : ./collect.sh <pid> [fichier_sortie.json]

set -u

PID="${1:-}"
if [ -z "$PID" ]; then
  echo "Usage: $0 <pid> [fichier_sortie.json]" >&2
  exit 1
fi

if ! kill -0 "$PID" 2>/dev/null; then
  echo "Erreur : le process $PID n'existe pas ou n'est pas accessible." >&2
  exit 1
fi

OUT="${2:-jvm_snapshot_${PID}_$(date +%Y%m%d_%H%M%S).json}"

command -v jcmd  >/dev/null 2>&1 || { echo "jcmd introuvable dans le PATH" >&2; exit 1; }
command -v jstat >/dev/null 2>&1 || { echo "jstat introuvable dans le PATH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Utilitaires JSON (pas de jq : on échappe nous-mêmes)
# ---------------------------------------------------------------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Transforme un bloc de texte brut en chaîne JSON (avec guillemets)
json_str_block() {
  printf '"%s"' "$(json_escape "$1")"
}

# ---------------------------------------------------------------------------
# 1. Collecte brute
# ---------------------------------------------------------------------------

TIMESTAMP="$(date -Iseconds 2>/dev/null || date)"
HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"

VM_VERSION="$(jcmd "$PID" VM.version 2>&1)"
VM_FLAGS="$(jcmd "$PID" VM.flags 2>&1)"
VM_SYSPROPS="$(jcmd "$PID" VM.system_properties 2>&1)"
GC_HEAP_INFO="$(jcmd "$PID" GC.heap_info 2>&1)"
GC_HISTO_RAW="$(jcmd "$PID" GC.class_histogram 2>&1)"
THREAD_DUMP="$(jcmd "$PID" Thread.print 2>&1)"
GCUTIL_RAW="$(jstat -gcutil "$PID" 2>&1)"
GCCAPACITY_RAW="$(jstat -gccapacity "$PID" 2>&1)"

# ---------------------------------------------------------------------------
# 2. Parsing jstat -gcutil (2 lignes : entêtes puis valeurs) -> tableau JSON
# ---------------------------------------------------------------------------

parse_gcutil() {
  local raw="$1"
  local header values
  header="$(echo "$raw" | sed -n '1p')"
  values="$(echo "$raw" | sed -n '2p')"

  if [ -z "$header" ] || [ -z "$values" ]; then
    printf '[]'
    return
  fi

  local -a keys vals
  read -r -a keys <<< "$header"
  read -r -a vals <<< "$values"

  local out="["
  local n=${#keys[@]}
  local i
  for ((i = 0; i < n; i++)); do
    [ $i -gt 0 ] && out+=","
    out+=$(printf '{"metric":%s,"value":%s}' \
      "$(json_str_block "${keys[$i]:-}")" \
      "$(json_str_block "${vals[$i]:-0}")")
  done
  out+="]"
  printf '%s' "$out"
}

GCUTIL_JSON="$(parse_gcutil "$GCUTIL_RAW")"

# ---------------------------------------------------------------------------
# 3. Parsing GC.class_histogram -> top 25 classes par octets, en JSON
#    Format attendu :
#      num     #instances         #bytes  class name (module)
#      -------------------------------------------------------
#         1:         12345         678900  java.lang.String
# ---------------------------------------------------------------------------

# Ne garde que les N premières entrées (le tableau est déjà trié par la JVM
# par taille décroissante, donc "les N premières" = "les N plus gros consommateurs").
parse_histogram() {
  local raw="$1"
  local max="${2:-25}"
  echo "$raw" | awk -v max="$max" '
    /^[[:space:]]*[0-9]+:/ {
      if (count >= max) next
      rank = $1; sub(":", "", rank)
      instances = $2
      bytes = $3
      cls = ""
      for (i = 4; i <= NF; i++) cls = cls (i > 4 ? " " : "") $i
      gsub(/"/, "\\\"", cls)
      printf("%s{\"rank\":%s,\"instances\":%s,\"bytes\":%s,\"class\":\"%s\"}", (count>0?",":""), rank, instances, bytes, cls)
      count++
    }
    BEGIN { count = 0 }
    END { }
  ' | awk 'BEGIN{printf "["} {printf "%s", $0} END{printf "]"}'
}

HISTO_JSON_TRIMMED="$(parse_histogram "$GC_HISTO_RAW" 25)"
[ -z "$HISTO_JSON_TRIMMED" ] && HISTO_JSON_TRIMMED="[]"

# ---------------------------------------------------------------------------
# 4. Analyse du thread dump : comptage des états + détection de deadlock
# ---------------------------------------------------------------------------

THREAD_TOTAL="$(echo "$THREAD_DUMP" | grep -cE '^"')"
COUNT_RUNNABLE="$(echo "$THREAD_DUMP" | grep -c 'java.lang.Thread.State: RUNNABLE')"
COUNT_WAITING="$(echo "$THREAD_DUMP" | grep -c 'java.lang.Thread.State: WAITING')"
COUNT_TIMED_WAITING="$(echo "$THREAD_DUMP" | grep -c 'java.lang.Thread.State: TIMED_WAITING')"
COUNT_BLOCKED="$(echo "$THREAD_DUMP" | grep -c 'java.lang.Thread.State: BLOCKED')"
COUNT_NEW="$(echo "$THREAD_DUMP" | grep -c 'java.lang.Thread.State: NEW')"
COUNT_TERMINATED="$(echo "$THREAD_DUMP" | grep -c 'java.lang.Thread.State: TERMINATED')"

if echo "$THREAD_DUMP" | grep -qi 'Found .* deadlock'; then
  DEADLOCK_DETECTED="true"
  DEADLOCK_DETAIL="$(echo "$THREAD_DUMP" | awk '/Found .* deadlock/,0')"
else
  DEADLOCK_DETECTED="false"
  DEADLOCK_DETAIL=""
fi

THREAD_STATES_JSON=$(cat <<EOF
{"runnable":${COUNT_RUNNABLE:-0},"waiting":${COUNT_WAITING:-0},"timed_waiting":${COUNT_TIMED_WAITING:-0},"blocked":${COUNT_BLOCKED:-0},"new":${COUNT_NEW:-0},"terminated":${COUNT_TERMINATED:-0}}
EOF
)

# ---------------------------------------------------------------------------
# 5. Assemblage du JSON final
# ---------------------------------------------------------------------------

cat > "$OUT" <<EOF
{
  "meta": {
    "pid": ${PID},
    "hostname": $(json_str_block "$HOSTNAME_VAL"),
    "collected_at": $(json_str_block "$TIMESTAMP")
  },
  "static": {
    "vm_version": $(json_str_block "$VM_VERSION"),
    "vm_flags": $(json_str_block "$VM_FLAGS"),
    "system_properties": $(json_str_block "$VM_SYSPROPS")
  },
  "dynamic": {
    "heap_info_raw": $(json_str_block "$GC_HEAP_INFO"),
    "gc_capacity_raw": $(json_str_block "$GCCAPACITY_RAW"),
    "gc_util": ${GCUTIL_JSON},
    "class_histogram": ${HISTO_JSON_TRIMMED},
    "threads": {
      "total": ${THREAD_TOTAL:-0},
      "states": ${THREAD_STATES_JSON},
      "deadlock_detected": ${DEADLOCK_DETECTED},
      "deadlock_detail": $(json_str_block "$DEADLOCK_DETAIL"),
      "raw_dump": $(json_str_block "$THREAD_DUMP")
    }
  }
}
EOF

echo "Snapshot écrit dans : $OUT"
