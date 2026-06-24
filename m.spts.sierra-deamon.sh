#!/bin/sh
#
# m.spts.sierra-deamon.sh
#
# Daemon de transfert des fichiers d'impression SIERRA vers le RPi RetroPrinter.
# Tourne en permanence sur le Sun IPC (SunOS) et scrute le répertoire du
# spooler d'impression (/var/spool/lpd/lpsierra) toutes les 60 secondes.
#
# Logique :
#   - Les fichiers de contrôle "cf*" sont supprimés immédiatement (non utilisés).
#   - Chaque fichier de données "df*" (ex: dfA047s12sun) est renommé en .raw,
#     puis transféré par FTP vers le RPi en double exemplaire :
#       * /home/pi/data/pdf  -> utilisé par RetroPrinter pour la conversion PDF
#       * /home/pi/data/raw  -> conservé pour l'identification du code QTG par
#                               ocr_rename.sh (lecture du contenu texte brut)
#   - Le nom dfA0NNs12sun est préservé intact côté RPi ; il sert de clé
#     d'appariement dans group_qtg.sh pour regrouper texte + graphique d'une
#     même QTG en un seul PDF (numéro de séquence NNN extrait par ocr_rename.sh
#     et conservé sous la forme §NNN dans le nom du PDF renommé).
#   - La tempo de 90s entre fichiers a été retirée : la sérialisation est
#     désormais assurée côté RPi par le flock bloquant de CustomScript.sh,
#     ce qui est plus robuste et ne pénalise pas le débit quand il n'y a
#     pas de collision réelle.
#
# Modifie /etc/printcap au démarrage pour rediriger les impressions SIERRA
# vers la fausse imprimante lpsierra (fichier de référence : printcap.sierra).

WATCH_DIR="/var/spool/lpd/lpsierra"
FTP_HOST="44.63.12.80"
FTP_USER="pi"
FTP_PASS="rootroot"
REMOTE_DIR="/home/pi/data/pdf"
REMOTE_DIR_OCR="/home/pi/data/raw"

echo "SIERRA FILE XFER DAEMON STARTUP"
echo "  ____ ___ _____ ____  ____      _      ____    _    _____ __  __  ___  _   _ "
echo " / ___|_ _| ____|  _ \|  _ \    / \    |  _ \  / \  | ____|  \/  |/ _ \| \ | |"
echo " \___ \| ||  _| | |_) | |_) |  / _ \   | | | |/ _ \ |  _| | |\/| | | | |  \| |"
echo "  ___) | || |___|  _ <|  _ <  / ___ \  | |_| / ___ \| |___| |  | | |_| | |\  |"
echo " |____/___|_____|_| \_\_| \_\/_/   \_\ |____/_/   \_\_____|_|  |_|\___/|_| \_|"
echo " "
echo "Script File Location : /usr/u2/tools/scripts/m.spts.sierra-deamon"
echo "Retro Printer Custom Script Location : /home/pi/CustomScript.sh"
echo " "

# Modifying the printcap to keep df files
cp /etc/printcap.sierra /etc/printcap
echo "/etc/printcap file updated"

# Infinite Loop
while :; do
    cd "$WATCH_DIR" || exit 1

    # Delete all files starting by "cf"
    for f in cf*; do
        [ -f "$f" ] && rm -f "$f"
    done

    # Vérifier s'il existe au moins un fichier df*
    set -- df*
    if [ ! -f "$1" ]; then
        echo "[SEARCH LOOP] No file found - waiting 60s"
        sleep 60
        continue
    fi

    echo "[FILE LOOP] File(s) Detected - treating file by file"

    # Traitement fichier par fichier
    for f in df*; do
        if [ -f "$f" ]; then
            echo "[FILE LOOP] Treating file: $f"

            case "$f" in
                *.raw) new_name="$f" ;;
                *) new_name="${f}.raw"
                   mv "$f" "$new_name" ;;
            esac

            # Création fichier commandes FTP
            {
                echo "user $FTP_USER $FTP_PASS"
                echo "cd $REMOTE_DIR"
                echo "put $new_name"
                echo "cd $REMOTE_DIR_OCR"
                echo "put $new_name"
                echo "bye"
            } > ftp_cmds.txt

            # Transfert FTP
            ftp -n "$FTP_HOST" < ftp_cmds.txt

            echo "[FILE LOOP] File Transferred: $new_name"

            # Nettoyage
            rm -f ftp_cmds.txt "$new_name"
        fi
    done
done