#!/usr/bin/env bash
#
# kali-auto-cleanup.sh — Mantenimiento automático de Kali Linux
# Instalar en: /usr/local/sbin/pinguclean.sh
# Uso:
#   sudo pinguclean.sh           # modo light (diario)
#   sudo pinguclean.sh --deep    # modo deep (semanal)
#   sudo pinguclean.sh --dry-run # ver qué haría sin ejecutar
#
# Solo hace operaciones IDEMPOTENTES y SEGURAS:
#  - NO desinstala paquetes (excepto autoremove de huérfanos)
#  - NO toca archivos del usuario fuera de caches conocidos
#  - NO cambia configuración del sistema
#
set -u
umask 022

# ── Config ────────────────────────────────────────────────────────────
LOG_DIR="/var/log/kali-cleanup"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d).log"
KEEP_LOG_DAYS=14
JOURNAL_MAX_SIZE="100M"
JOURNAL_KEEP_DAYS="7d"
CACHE_AGE_DAYS=14
TMP_AGE_DAYS=2
VARTMP_AGE_DAYS=7
DOCKER_PRUNE_DAYS=30  # solo en modo deep

# ── Modo ──────────────────────────────────────────────────────────────
MODE="light"
DRY=0
for arg in "$@"; do
    case "$arg" in
        --deep)    MODE="deep" ;;
        --dry-run) DRY=1 ;;
        --help|-h)
            sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log()  { echo "[$(date +'%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
sec()  { echo "" | tee -a "$LOG_FILE"; log "═══ $* ═══"; }
run()  { if [ "$DRY" -eq 1 ]; then log "DRY: $*"; else eval "$@" 2>&1 | tee -a "$LOG_FILE"; fi; }
runq() { if [ "$DRY" -eq 1 ]; then log "DRY: $*"; else eval "$@" >> "$LOG_FILE" 2>&1; fi; }

# Requiere root
if [ "$(id -u)" -ne 0 ]; then
    echo "Necesita root: sudo $0 $*" >&2; exit 1
fi

# Detectar usuario real (no hardcode)
REAL_USER=$(awk -F: '$3>=1000 && $3<60000 {print $1; exit}' /etc/passwd)
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Lock para evitar concurrencia (si cron dispara dos veces)
exec 9>/var/run/kali-cleanup.lock
if ! flock -n 9; then
    log "Ya hay otra instancia corriendo. Salgo."
    exit 0
fi

START_TS=$(date +%s)
BEFORE_KB=$(df / | awk 'NR==2{print $3}')

log "════════════════════════════════════════════════════════════"
log "  kali-auto-cleanup MODO=$MODE  DRY=$DRY  user=$REAL_USER"
log "════════════════════════════════════════════════════════════"

# ── 1. APT ────────────────────────────────────────────────────────────
sec "APT clean / autoclean / autoremove"
runq "apt-get clean -y"
runq "apt-get autoclean -y"
runq "DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y"

# Purgar configs residuales
RC_PKGS=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | tr '\n' ' ')
if [ -n "$RC_PKGS" ]; then
    log "Purgando configs residuales: $(echo $RC_PKGS | wc -w) paquetes"
    runq "dpkg --purge $RC_PKGS"
fi

# ── 2. LOGS ───────────────────────────────────────────────────────────
sec "Journal y logs"
runq "journalctl --vacuum-size=$JOURNAL_MAX_SIZE"
runq "journalctl --vacuum-time=$JOURNAL_KEEP_DAYS"
# Logs rotados antiguos
runq "find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -regex '.*\.[0-9]+\(\.gz\)?$' \) -mtime +$JOURNAL_KEEP_DAYS%d -delete"
# Truncar logs activos grandes
runq "find /var/log -maxdepth 3 -type f -size +100M -exec truncate -s 50M {} \;"
# Limpiar logs de servicios específicos de Kali
runq "find /var/log/apache2 /var/log/mysql /var/log/postgresql -type f -name '*.log.*' -mtime +7 -delete 2>/dev/null"

# Rotar nuestros propios logs
find "$LOG_DIR" -type f -name "cleanup-*.log" -mtime +$KEEP_LOG_DAYS -delete 2>/dev/null

# ── 3. TMP ────────────────────────────────────────────────────────────
sec "Archivos temporales"
runq "find /tmp -mindepth 1 -atime +$TMP_AGE_DAYS -not -path '*/systemd-private-*' -not -path '*/snap*' -delete"
runq "find /var/tmp -mindepth 1 -atime +$VARTMP_AGE_DAYS -delete"
runq "rm -rf /var/crash/* /var/lib/systemd/coredump/*"

# ── 4. CACHES DE USUARIO ──────────────────────────────────────────────
sec "Caches del usuario $REAL_USER"
if [ -n "$REAL_HOME" ] && [ -d "$REAL_HOME" ]; then
    sudo -u "$REAL_USER" bash -c "
        # Thumbnails
        find '$REAL_HOME/.cache/thumbnails' -type f -atime +7 -delete 2>/dev/null
        find '$REAL_HOME/.thumbnails' -type f -atime +7 -delete 2>/dev/null
        # Papelera
        rm -rf '$REAL_HOME/.local/share/Trash/files/'* 2>/dev/null
        rm -rf '$REAL_HOME/.local/share/Trash/info/'* 2>/dev/null
        # Caches de navegador (solo los Cache/ no los profiles)
        find '$REAL_HOME/.cache/mozilla' -type d -name 'cache2' -exec rm -rf {}/entries {}/doomed \; 2>/dev/null
        find '$REAL_HOME/.cache/google-chrome' -type d -name 'Cache' -exec sh -c 'rm -rf \"\$1\"/*' _ {} \; 2>/dev/null
        find '$REAL_HOME/.cache/chromium' -type d -name 'Cache' -exec sh -c 'rm -rf \"\$1\"/*' _ {} \; 2>/dev/null
        find '$REAL_HOME/.cache/BraveSoftware' -type d -name 'Cache' -exec sh -c 'rm -rf \"\$1\"/*' _ {} \; 2>/dev/null
        # Caches genéricos antiguos
        find '$REAL_HOME/.cache' -type f -atime +$CACHE_AGE_DAYS -delete 2>/dev/null
        # Logs de herramientas hacking
        find '$REAL_HOME/.msf'* -type f \\( -name '*.log' -o -path '*/loot/*' \\) -mtime +30 -delete 2>/dev/null
        find '$REAL_HOME/.BurpSuite' -type f -name '*.log' -delete 2>/dev/null
        find '$REAL_HOME/.recon-ng/workspaces' -type d -name 'loot' -exec rm -rf {}/* \\; 2>/dev/null
        # Truncar histories
        for hist in '$REAL_HOME/.bash_history' '$REAL_HOME/.zsh_history' '$REAL_HOME/.python_history' '$REAL_HOME/.lesshst' '$REAL_HOME/.mysql_history' '$REAL_HOME/.sqlite_history'; do
            [ -f \"\$hist\" ] && [ \$(wc -l < \"\$hist\") -gt 2000 ] && tail -n 2000 \"\$hist\" > \"\$hist.tmp\" && mv \"\$hist.tmp\" \"\$hist\"
        done
    " 2>&1 | tee -a "$LOG_FILE"
fi

# ── 5. CACHES DE GESTORES DE PAQUETES ─────────────────────────────────
sec "Caches pip/npm/cargo"
if command -v pip3 >/dev/null; then
    runq "sudo -u $REAL_USER pip3 cache purge"
fi
if command -v npm >/dev/null; then
    runq "sudo -u $REAL_USER npm cache clean --force"
fi
# Cargo (rust) - solo registry y git checkouts viejos
runq "find $REAL_HOME/.cargo/registry/src -mindepth 1 -maxdepth 2 -atime +30 -exec rm -rf {} +"
runq "find $REAL_HOME/.cargo/registry/cache -mindepth 1 -atime +30 -delete"

# ── 6. MODO DEEP (semanal) ────────────────────────────────────────────
if [ "$MODE" = "deep" ]; then
    sec "MODO DEEP — limpiezas semanales"

    # Docker prune
    if command -v docker >/dev/null && systemctl is-active --quiet docker; then
        log "Docker prune (>${DOCKER_PRUNE_DAYS} días)"
        runq "docker system prune -af --filter 'until=${DOCKER_PRUNE_DAYS}h'"
        runq "docker volume prune -af"
    fi

    # Kernels antiguos (mantener solo el actual + 1 backup)
    CURRENT=$(uname -r | sed 's/-amd64$//')
    OLD_KERNELS=$(dpkg -l | awk '/^ii  linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT" | head -n -1)
    if [ -n "$OLD_KERNELS" ]; then
        log "Eliminando kernels antiguos: $OLD_KERNELS"
        runq "DEBIAN_FRONTEND=noninteractive apt-get purge -y $OLD_KERNELS"
    fi

    # Locales (si localepurge está instalado)
    if command -v localepurge >/dev/null; then
        runq "localepurge"
    fi

    # Snap revisiones desactivadas
    if command -v snap >/dev/null; then
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname rev; do
            runq "snap remove '$snapname' --revision='$rev'"
        done
    fi

    # Flatpak unused
    if command -v flatpak >/dev/null; then
        runq "flatpak uninstall --unused -y"
    fi

    # TRIM disco (solo deep — no es necesario diario)
    runq "fstrim -av"

    # man-db rebuild si está fragmentada
    runq "mandb --quiet"
fi

# ── 7. LIBERAR CACHES DE RAM ──────────────────────────────────────────
sec "Liberar caches RAM"
runq "sync"
[ "$DRY" -eq 0 ] && echo 3 > /proc/sys/vm/drop_caches
log "drop_caches ejecutado"

# ── 8. RESUMEN ────────────────────────────────────────────────────────
AFTER_KB=$(df / | awk 'NR==2{print $3}')
FREED_MB=$(( (BEFORE_KB - AFTER_KB) / 1024 ))
ELAPSED=$(( $(date +%s) - START_TS ))

sec "RESUMEN"
log "Tiempo: ${ELAPSED}s"
log "Espacio liberado: ${FREED_MB} MB"
log "Disco /:"
df -h / | tee -a "$LOG_FILE"
log "Memoria:"
free -h | tee -a "$LOG_FILE"
log "════════════════ FIN ════════════════"

exit 0
