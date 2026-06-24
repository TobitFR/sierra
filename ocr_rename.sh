#!/bin/bash
#
# ocr_rename.sh
#
# Renomme un PDF issu de RetroPrinter en s'appuyant sur le contenu de son
# fichier RAW d'origine (impression brute envoyée par le Sun via le daemon
# m_spts_sierra-deamon, sous la forme dfA0NNs12sun.raw).
#
# Logique :
#   - RetroPrinter génère ses propres noms de fichiers
#     (retro-printer_YYYY-MM-DD_HHMMSS[-FULL].pdf), sans lien avec le nom
#     du RAW d'origine (dfA0NNs12sun.raw). L'appariement PDF↔RAW se fait
#     donc par "RAW le plus récent dans /home/pi/data/raw/", ce qui est
#     fiable car RetroPrinter traite les fichiers un par un ET CustomScript.sh
#     est protégé par un flock bloquant — au moment où ce script s'exécute,
#     un seul RAW est présent et c'est forcément le bon.
#   - Le contenu du RAW est lu pour extraire le simulateur (SIMULATOR :) et
#     le code QTG (pattern CODE, ou à défaut les premières lignes non vides).
#   - Si un RAW est présent mais qu'aucun code n'est identifiable, le fichier
#     est catégorisé [GRAPH] (cas des impressions de courbes, illisibles en
#     l'absence de pattern texte exploitable). Si aucun RAW n'est trouvé du
#     tout, le fichier est catégorisé [UNKNOWN].
#   - Avant suppression du RAW, son numéro de séquence spooler (dfA0NN -> NNN)
#     est extrait et conservé dans le nom final du PDF sous la forme " §NNN".
#     Cette séquence sert de clé d'appariement à l'étape suivante du pipeline
#     (group_qtg.sh) pour regrouper texte et graphique d'une même QTG en un
#     seul PDF. Un PDF sans RAW exploitable n'a pas de §NNN et sera donc
#     immédiatement traité comme un fichier indépendant par group_qtg.sh.
#
# Appelé par CustomScript.sh, juste après la conversion RetroPrinter et avant
# l'étape de groupage et le transfert FTP vers le MMGT.

# Configuration
TARGET_DIR="${1:-.}"
LOG_FILE="/var/log/retroprinter.log"

# --- LOGGING ---
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# Ensure we have required tools
if ! command -v pdftoppm &> /dev/null; then
    log "ERROR" "pdftoppm (poppler-utils) is not installed. Please run: sudo apt install poppler-utils"
    exit 1
fi

# Function to clean and validate QTG code
clean_qtg() {
    local input="$1"
    echo "$input" | sed -E 's/.*(CODE|Code|code)[[:space:]]*:?[[:space:]]*//' | \
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | \
    tr -cd '[:alnum:] .-' | awk '{print $1, $2}' | sed 's/[[:space:]]*$//'
}

# Configuration for RAW buffer
RAW_DIR="/home/pi/data/raw"
[ ! -d "$RAW_DIR" ] && mkdir -p "$RAW_DIR"

# Check arguments
PDF_ARG=""
RAW_ARG=""

if [ -f "$1" ]; then
    PDF_ARG="$1"
    TARGET_DIR=$(dirname "$1")
    [ -f "$2" ] && RAW_ARG="$2"
elif [ -d "$1" ]; then
    TARGET_DIR="$1"
else
    TARGET_DIR="/home/pi/data/pdf"
    [ ! -d "$TARGET_DIR" ] && TARGET_DIR="."
fi

# Auto-detect latest unprocessed PDF
if [ -z "$PDF_ARG" ]; then
    PDF_ARG=$(ls -t "$TARGET_DIR"/*.pdf 2>/dev/null | grep -vE "[0-9]{4}-[0-9]{2}-[0-9]{2}" | head -n 1)
    if [ -n "$PDF_ARG" ]; then
        log "INFO" "Auto-detected latest PDF: $(basename "$PDF_ARG")"
    fi
fi

process_file() {
    local file="$1"
    local forced_raw="$2"
    local filename=$(basename "$file")

    # Skip if already renamed
    if [[ "$filename" =~ ^\[.*\] ]]; then
        log "INFO" "Skipping already renamed file: $filename"
        return
    fi

    log "INFO" "Processing: $filename"

    QTG_CODE=""
    PREFIX=""
    OUTCOME=""
    SEQ_NUM=""

    # --- RAW FILE EXTRACTION (PRIMARY) ---
    local RAW_FILE=""

    if [ -f "$forced_raw" ]; then
        RAW_FILE="$forced_raw"
    else
        # RetroPrinter génère ses propres noms de fichiers (retro-printer_YYYY-MM-DD_HHMMSS[-FULL].pdf)
        # sans lien avec le nom du RAW d'origine (dfA0NNs12sun.raw). Un appariement par nom
        # est donc impossible. On prend le RAW le plus récent, ce qui est fiable car :
        #   - RetroPrinter traite les fichiers un par un (jamais deux conversions en parallèle)
        #   - CustomScript.sh est protégé par un flock bloquant (exécutions sérialisées)
        # => au moment où ce script s'exécute, un seul RAW est présent et c'est forcément le bon.
        RAW_FILE=$(ls -t "$RAW_DIR"/*.raw 2>/dev/null | head -n 1)
        if [ -z "$RAW_FILE" ]; then
            RAW_FILE=$(ls -t "$TARGET_DIR"/*.raw 2>/dev/null | head -n 1)
        fi
    fi

    if [ -n "$RAW_FILE" ]; then
        log "INFO" "Reading RAW file: $(basename "$RAW_FILE")"

        # Extract Simulator Version (Prefix)
        local sim_line=$(grep -i "SIMULATOR :" "$RAW_FILE" | head -n 1)
        if [ -n "$sim_line" ]; then
            local sim_model=$(echo "$sim_line" | sed -E 's/.*SIMULATOR[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/' | tr '_' ' ')
            if [ -n "$sim_model" ]; then
                PREFIX="[$sim_model]"
                log "INFO" "Found Simulator: $sim_model"
            fi
        fi

        # Extract QTG Code via CODE pattern
        local raw_extract_line=$(grep -i "CODE" "$RAW_FILE" | head -n 1)
        if [ -n "$raw_extract_line" ]; then
            local extract=$(clean_qtg "$raw_extract_line")
            if [ -n "$extract" ] && [ ${#extract} -ge 3 ]; then
                QTG_CODE="$extract"
                OUTCOME="RAW_CODE_PATTERN"
                log "INFO" "Extracted QTG from RAW (CODE pattern): $QTG_CODE"
            fi
        fi

        # Fallback: top non-empty lines of RAW
        if [ -z "$QTG_CODE" ]; then
            local raw_extract_line=$(sed '/^[[:space:]]*$/d' "$RAW_FILE" | head -n 5 | while read -r line; do
                local extract=$(clean_qtg "$line")
                if [ -n "$extract" ] && [ ${#extract} -ge 3 ]; then
                    echo "$extract"
                    break
                fi
            done | head -n 1)
            if [ -n "$raw_extract_line" ]; then
                QTG_CODE="$raw_extract_line"
                OUTCOME="RAW_TOP_LINES"
                log "INFO" "Extracted QTG from RAW (top lines): $QTG_CODE"
            fi
        fi

        # RAW présent mais aucun code trouvé = graphique identifié
        if [ -z "$QTG_CODE" ]; then
            log "WARN" "RAW found but no QTG code extracted — categorizing as GRAPH."
            QTG_CODE="GRAPH"
            PREFIX="[GRAPH]"
            OUTCOME="GRAPH"
        fi

        # Extraction du numéro de séquence spooler (ex: dfA047s12sun -> 047)
        # Conservé pour l'étape de groupage texte/graphique (group_qtg.sh).
        local raw_basename=$(basename "$RAW_FILE")
        SEQ_NUM=$(echo "$raw_basename" | sed -nE 's/^dfA([0-9]{3}).*/\1/p')
        if [ -n "$SEQ_NUM" ]; then
            log "INFO" "Extracted spooler sequence: $SEQ_NUM"
        else
            log "WARN" "Could not extract spooler sequence from: $raw_basename"
        fi

        log "INFO" "Cleaning up RAW file: $(basename "$RAW_FILE")"
        rm -f "$RAW_FILE"

    else
        # Pas de RAW du tout = impossible d'identifier la source
        log "WARN" "No RAW file found for $filename — categorizing as UNKNOWN."
        QTG_CODE="unknown_ocr_failed"
        PREFIX="[UNKNOWN]"
        OUTCOME="UNKNOWN"
    fi

    # --- RENAME ---
    local file_date=$(date -r "$file" "+%Y-%m-%d %H-%M-%S")
    local seq_suffix=""
    [ -n "$SEQ_NUM" ] && seq_suffix=" §${SEQ_NUM}"
    local new_filename="${PREFIX} ${QTG_CODE} ${file_date}${seq_suffix}.pdf"
    local target_path="$TARGET_DIR/$new_filename"

    local counter=1
    while [ -f "$target_path" ]; do
        new_filename="${PREFIX} ${QTG_CODE} ${file_date}${seq_suffix}_${counter}.pdf"
        target_path="$TARGET_DIR/$new_filename"
        ((counter++))
    done

    if [ "$filename" != "$new_filename" ]; then
        mv "$file" "$target_path"
        log "INFO" "Renamed [${OUTCOME}]: $filename -> $new_filename"
    else
        log "INFO" "File already named correctly: $filename"
    fi
}

# --- EXECUTION ---
if [ -n "$PDF_ARG" ]; then
    process_file "$PDF_ARG" "$RAW_ARG"
else
    log "INFO" "Batch mode: scanning $TARGET_DIR"
    find "$TARGET_DIR" -maxdepth 1 -name "*.pdf" -print0 | while IFS= read -r -d '' pdf; do
        process_file "$pdf"
    done
fi