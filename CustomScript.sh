#!/bin/bash
#
# CustomScript.sh
#
# Orchestrateur principal du pipeline RetroPrinter sur le RPi. Déclenché par
# RetroPrinter à chaque fin de conversion .raw -> .pdf d'une impression reçue
# du Sun (donc potentiellement déclenché plusieurs fois en quelques secondes
# si une QTG envoie texte et graphique séparément, maintenant que la tempo
# de 90s entre envois FTP côté Sun a été retirée du daemon).
#
# Tout le script est protégé par un flock BLOQUANT : si une exécution est
# déjà en cours, la nouvelle attend patiemment son tour plutôt que d'abandonner,
# pour ne perdre aucun fichier fraîchement converti. Remplace la tempo de 90s :
# au lieu d'espacer les envois en amont, on sérialise le traitement en aval.
#
# Étapes, dans l'ordre :
#   1. ocr_rename.sh   - identifie et renomme le PDF à partir de son RAW
#                         d'origine (code QTG, simulateur, séquence spooler).
#   2. group_qtg.sh     - tente de regrouper ce PDF avec son éventuel
#                         partenaire (texte + graphique d'une même QTG) en un
#                         seul PDF fusionné. Relancé aussi par cron toutes les
#                         2 minutes pour libérer les fichiers solo orphelins
#                         (timeout) même en l'absence de nouvelle conversion.
#   3. Transfert FTP    - envoie vers la machine MMGT (D:/QTG) tout PDF du
#                         dossier source qui n'est pas déjà présent côté
#                         distant. Les PDF encore en attente d'appariement
#                         (suffixe " §NNN") sont exclus du transfert.
#   4. Purge /tmp       - nettoyage des anciens fichiers retro-printer_*.

LOG_FILE="/var/log/sierra.log"
LOCK_FILE="/tmp/customscript.lock"
LOG_LEVEL="INFO"   # DEBUG = tout logguer | INFO = événements significatifs uniquement | SILENT = erreurs seulement

# --- LOGGING ---
log() {
    local level="$1"
    shift
    [ "$LOG_LEVEL" = "SILENT" ] && [ "$level" != "ERROR" ] && return
    [ "$LOG_LEVEL" = "INFO"   ] && [ "$level" = "DEBUG"  ] && return
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# --- LOCK BLOQUANT : sérialise les exécutions concurrentes, n'en abandonne aucune ---
exec 200>"$LOCK_FILE"
if ! flock -w 600 200; then
    log "ERROR" "Could not acquire lock after 600s wait — aborting this run."
    exit 1
fi
log "DEBUG" "Lock acquired, starting run."

#------------------------------------
# OCR Rename
# $1 = output_path (ex: /home/pi/data/pdf/)
# $2 = filename sans suffixe de page (ex: retro-printer_2026-06-27_185249.pdf)
#      Le fichier réel peut avoir un suffixe de page (-1, -2) ou -FULL :
#      retro-printer_2026-06-27_185249-1.pdf ou retro-printer_2026-06-27_185249-FULL.pdf
#      On résout le nom exact par glob avant de passer le chemin à ocr_rename.sh.
PDF_BASE="${2%.pdf}"
PDF_REAL=$(ls "${1}${PDF_BASE}"*.pdf 2>/dev/null | head -n 1)
if [ -z "$PDF_REAL" ]; then
    log "ERROR" "Cannot find PDF matching '${1}${PDF_BASE}*.pdf' — aborting."
    exit 1
fi
log "DEBUG" "Starting ocr_rename.sh for: $(basename "$PDF_REAL")"
/home/pi/ocr_rename.sh "$PDF_REAL"
if [ $? -ne 0 ]; then
    log "ERROR" "ocr_rename.sh exited with error - FTP transfer aborted"
    exit 1
fi
log "DEBUG" "ocr_rename.sh completed"

#------------------------------------
# Group QTG (texte + graphique) en un seul PDF
log "DEBUG" "Starting group_qtg.sh"
/home/pi/group_qtg.sh
if [ $? -ne 0 ]; then
    log "ERROR" "group_qtg.sh exited with error - continuing anyway (non-blocking)"
fi
log "DEBUG" "group_qtg.sh completed"

#------------------------------------
# FTP Transfer to MMGT Computer D:/QTG
SRC_DIR="/home/pi/data/pdf/"
FTP_USER="pi"
FTP_PASS="rootroot"
FTP_IP="44.63.12.99"
FTP_DIR="/"

log "DEBUG" "Fetching FTP file list from $FTP_IP"
ftp_file_list=$(lftp -u "$FTP_USER","$FTP_PASS" ftp://$FTP_IP -e "set ftp:ssl-allow no; cd $FTP_DIR; cls; bye")

file_exists_on_ftp() {
    local filename="$1"
    echo "$ftp_file_list" | grep -qx "$filename"
}

for file in "$SRC_DIR"*.pdf; do
    [ -f "$file" ] || continue

    basefile=$(basename "$file")

    # Ne pas transférer un PDF qui attend encore son partenaire texte/graphique
    # (group_qtg.sh le libère une fois fusionné ou après timeout solo).
    if [[ "$basefile" =~ §[0-9]{3}\.pdf$ ]]; then
        log "DEBUG" "Still awaiting pairing, skipping for now: $basefile"
        continue
    fi

    if file_exists_on_ftp "$basefile"; then
        log "DEBUG" "Already on FTP, skipping: $basefile"
    else
        log "INFO" "Transferring: $basefile"
        lftp -u "$FTP_USER","$FTP_PASS" ftp://$FTP_IP -e "set ftp:ssl-allow no; cd $FTP_DIR; put \"$file\"; bye"
        if [ $? -eq 0 ]; then
            log "INFO" "Transfer OK: $basefile"
            # rm "$file"
        else
            log "ERROR" "Transfer FAILED: $basefile"
        fi
    fi
done

#------------------------------------
# Purge /tmp
log "DEBUG" "Purging old /tmp/retro-printer_* files"
cd /tmp
today=$(date +%Y-%m-%d)

for f in retro-printer_*; do
    date_fichier=${f#retro-printer_}
    if [ "$date_fichier" \< "$today" ]; then
        rm -- "$f"
        log "DEBUG" "Deleted tmp file: $f"
    fi
done

log "DEBUG" "CustomScript completed"