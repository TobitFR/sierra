#!/bin/bash
#
# group_qtg.sh
#
# Regroupe les paires de PDF "texte" + "graphique" d'une même QTG en un seul
# PDF, en s'appuyant sur le numéro de séquence du spooler d'impression Sun
# (dfA0NN, conservé par ocr_rename.sh dans le nom de fichier sous la forme
# " §NNN" juste avant l'extension .pdf).
#
# Règles d'appariement (écart de séquence de 1, modulo 1000) :
#   - Texte  + [GRAPH]   → paire valide, texte en page 1
#   - [UNKNOWN] + [GRAPH] → paire autorisée (RAW absent mais probablement
#                           un texte non identifié), log WARNING
#   - Texte  + Texte     → REFUSÉ : deux QTG distinctes se suivant,
#                           chacune traitée en solo après timeout
#   - [GRAPH] + [GRAPH]  → REFUSÉ : même raison
#   - [UNKNOWN] + Texte  → REFUSÉ : trop ambigu pour forcer la fusion
#   - [UNKNOWN] + [UNKNOWN] → REFUSÉ
#
# Un fichier sans partenaire valide est laissé en l'état tant qu'il n'a
# pas dépassé SOLO_TIMEOUT_SECONDS ; passé ce délai, il est libéré "solo"
# (le §NNN est simplement retiré de son nom).
# Un fichier [UNKNOWN] ne cherche jamais un partenaire texte : il attend
# uniquement un [GRAPH] consécutif, ou part en solo après timeout.
# Un fichier sans §NNN du tout (usage non-QTG) est ignoré par ce script.
#
# Appelé par CustomScript.sh après ocr_rename.sh, et par cron toutes les
# 2 minutes pour garantir qu'un fichier orphelin finisse par partir.
# Protégé par flock pour éviter toute collision entre exécutions concurrentes.

TARGET_DIR="${1:-/home/pi/data/pdf}"
LOG_FILE="/var/log/retroprinter.log"
LOCK_FILE="/tmp/group_qtg.lock"
SOLO_TIMEOUT_SECONDS=300   # 5 minutes
LOG_LEVEL="INFO"   # DEBUG = tout logguer | INFO = événements significatifs uniquement | SILENT = erreurs seulement

# --- LOGGING ---
log() {
    local level="$1"
    shift
    [ "$LOG_LEVEL" = "SILENT" ] && [ "$level" != "ERROR" ] && return
    [ "$LOG_LEVEL" = "INFO"   ] && [ "$level" = "DEBUG"  ] && return
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# --- LOCK : une seule exécution à la fois ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "DEBUG" "group_qtg.sh already running elsewhere, skipping this pass."
    exit 0
fi

if ! command -v pdfunite &> /dev/null; then
    log "ERROR" "pdfunite (poppler-utils) is not installed. Please run: sudo apt install poppler-utils"
    exit 1
fi

# Extrait le §NNN d'un nom de fichier (vide si absent)
extract_seq() {
    echo "$1" | sed -nE 's/.*§([0-9]{3}).*\.pdf$/\1/p'
}

# Écart modulo 1000 entre deux séquences (gère le rollover 999 -> 000)
# Renvoie le plus petit écart "circulaire" entre seq1 et seq2 (toujours positif)
seq_distance() {
    local a=$((10#$1))
    local b=$((10#$2))
    local diff=$(( (b - a + 1000) % 1000 ))
    local diff_rev=$(( (a - b + 1000) % 1000 ))
    if [ "$diff_rev" -lt "$diff" ]; then
        echo "$diff_rev"
    else
        echo "$diff"
    fi
}

# Le fichier B vient-il "après" A dans le sens circulaire (écart de +1) ?
is_next_seq() {
    local a=$((10#$1))
    local b=$((10#$2))
    local diff=$(( (b - a + 1000) % 1000 ))
    [ "$diff" -eq 1 ]
}

# Un fichier est-il un [GRAPH] ?
is_graph() {
    [[ "$1" =~ ^\[GRAPH\] ]]
}

# Un fichier est-il un [UNKNOWN] (RAW absent, type indéterminé) ?
is_unknown() {
    [[ "$1" =~ ^\[UNKNOWN\] ]]
}

# Un fichier est-il un texte identifié (ni GRAPH ni UNKNOWN) ?
is_text() {
    ! is_graph "$1" && ! is_unknown "$1"
}

# Vérifie si deux fichiers forment une paire valide selon les règles métier.
# Renvoie 0 (vrai) si appariement autorisé, 1 sinon.
# Paramètres : file_a file_b
is_valid_pair() {
    local a="$1" b="$2"
    if   is_text "$a"    && is_graph "$b";   then return 0   # texte + graph   ✅
    elif is_graph "$a"   && is_text "$b";    then return 0   # graph + texte   ✅
    elif is_unknown "$a" && is_graph "$b";   then return 0   # unknown + graph ✅ (warning)
    elif is_graph "$a"   && is_unknown "$b"; then return 0   # graph + unknown ✅ (warning)
    else return 1                                            # tout autre cas  ❌
    fi
}

# Renvoie 0 si la paire implique un [UNKNOWN] (pour logguer un warning)
pair_has_unknown() {
    is_unknown "$1" || is_unknown "$2"
}

# Retire le suffixe " §NNN" d'un nom de fichier
strip_seq() {
    echo "$1" | sed -E 's/ §[0-9]{3}(\.pdf)$/\1/'
}

cd "$TARGET_DIR" || { log "ERROR" "Cannot cd to $TARGET_DIR"; exit 1; }

# Liste des PDF candidats au groupage (ceux qui ont encore un §NNN)
mapfile -t candidates < <(find . -maxdepth 1 -name "*.pdf" -print0 | xargs -0 -n1 basename 2>/dev/null | grep -E '§[0-9]{3}\.pdf$')

if [ ${#candidates[@]} -eq 0 ]; then
    log "DEBUG" "group_qtg.sh: no sequenced PDF candidates found."
    exit 0
fi

log "DEBUG" "group_qtg.sh: ${#candidates[@]} sequenced candidate(s) found."

declare -A processed

for file_a in "${candidates[@]}"; do
    [ -f "$file_a" ] || continue
    [ -n "${processed[$file_a]}" ] && continue

    seq_a=$(extract_seq "$file_a")
    [ -z "$seq_a" ] && continue

    partner=""
    partner_seq=""

    # Recherche d'un partenaire à séquence consécutive ET type compatible
    for file_b in "${candidates[@]}"; do
        [ -f "$file_b" ] || continue
        [ "$file_b" == "$file_a" ] && continue
        [ -n "${processed[$file_b]}" ] && continue

        seq_b=$(extract_seq "$file_b")
        [ -z "$seq_b" ] && continue

        dist=$(seq_distance "$seq_a" "$seq_b")
        if [ "$dist" -eq 1 ]; then
            if is_valid_pair "$file_a" "$file_b"; then
                partner="$file_b"
                partner_seq="$seq_b"
                break
            else
                log "WARN" "Consecutive pair §${seq_a}/§${seq_b} rejected ($(basename "$file_a") + $(basename "$file_b") — incompatible types, both will go solo after timeout)."
            fi
        fi
    done

    if [ -n "$partner" ]; then
        # --- PAIRE VALIDE : déterminer l'ordre (texte en page 1, graph en page 2) ---
        if pair_has_unknown "$file_a" "$partner"; then
            log "WARN" "Pairing involves an [UNKNOWN] file — RAW was missing at identification time. Merging anyway."
        fi

        # Le texte identifié (ou l'UNKNOWN si pas de texte) passe en premier
        if is_text "$file_a" || (is_unknown "$file_a" && is_unknown "$partner" && is_next_seq "$seq_a" "$partner_seq"); then
            text_file="$file_a"
            graph_file="$partner"
        elif is_text "$partner"; then
            text_file="$partner"
            graph_file="$file_a"
        elif is_unknown "$file_a" && is_graph "$partner"; then
            # UNKNOWN en premier (probablement le texte), GRAPH en second
            text_file="$file_a"
            graph_file="$partner"
        else
            # GRAPH + UNKNOWN : GRAPH probablement arrivé avant, UNKNOWN = texte manqué
            text_file="$partner"
            graph_file="$file_a"
        fi

        output_name=$(strip_seq "$text_file")

        # Anti-collision si le nom de sortie existe déjà
        out_counter=1
        base_output="$output_name"
        while [ -f "$output_name" ]; do
            output_name="${base_output%.pdf}_${out_counter}.pdf"
            ((out_counter++))
        done

        log "INFO" "Pairing found: '$text_file' + '$graph_file' -> '$output_name'"

        tmp_output="${output_name}.tmp"
        if pdfunite "$text_file" "$graph_file" "$tmp_output" 2>>"$LOG_FILE"; then
            mv "$tmp_output" "$output_name"
            rm -f "$text_file" "$graph_file"
            log "INFO" "Merged successfully: $output_name"
        else
            rm -f "$tmp_output"
            log "ERROR" "pdfunite failed for '$text_file' + '$graph_file' — left untouched for manual review."
        fi

        processed["$file_a"]=1
        processed["$partner"]=1

    else
        # --- PAS DE PARTENAIRE : vérifier le timeout ---
        file_age=$(( $(date +%s) - $(date -r "$file_a" +%s) ))
        if [ "$file_age" -ge "$SOLO_TIMEOUT_SECONDS" ]; then
            solo_name=$(strip_seq "$file_a")
            if [ "$solo_name" != "$file_a" ]; then
                solo_counter=1
                base_solo="$solo_name"
                while [ -f "$solo_name" ]; do
                    solo_name="${base_solo%.pdf}_${solo_counter}.pdf"
                    ((solo_counter++))
                done
                mv "$file_a" "$solo_name"
                log "INFO" "No partner found for '$file_a' after ${file_age}s — released as solo: '$solo_name'"
            fi
            processed["$file_a"]=1
        else
            log "DEBUG" "No partner (yet) for '$file_a' (age ${file_age}s < ${SOLO_TIMEOUT_SECONDS}s) — will retry next pass."
        fi
    fi
done

log "DEBUG" "group_qtg.sh: pass completed."