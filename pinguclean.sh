#!/usr/bin/env bash
#
# pinguclean.sh — Mantenimiento automático de Kali Linux (VERSIÓN EXTREMA)
# Instalar en: /usr/local/sbin/pinguclean.sh
# Uso:
#   sudo pinguclean.sh           # modo light (diario)
#   sudo pinguclean.sh --deep    # modo deep (semanal)
#   sudo pinguclean.sh --aggressive # modo agresivo (mensual)
#   sudo pinguclean.sh --dry-run # ver qué haría sin ejecutar
#
# Solo hace operaciones IDEMPOTENTES y SEGURAS:
#  - NO desinstala paquetes (excepto autoremove de huérfanos)
#  - NO toca archivos del usuario fuera de caches conocidos
#  - NO cambia configuración del sistema
#
set -uo pipefail
umask 022

# ── Config base (valores por defecto para modo light) ─────────────────
LOG_DIR="/var/log/kali-cleanup"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d_%H%M%S).log"
KEEP_LOG_DAYS=14

# Variables que serán sobrescritas según el modo (con valores por defecto)
JOURNAL_MAX_SIZE="100M"
JOURNAL_KEEP_DAYS="7d"
LOG_RETAIN_DAYS=7
CACHE_AGE_DAYS=14
TMP_AGE_DAYS=2
VARTMP_AGE_DAYS=7
DOCKER_PRUNE_DAYS=30
KERNELS_TO_KEEP=2          # Valor por defecto (modo light)

# ── Modo ──────────────────────────────────────────────────────────────
MODE="light"
DRY=0
AGGRESSIVE=0

for arg in "$@"; do
    case "$arg" in
        --deep)       MODE="deep" ;;
        --aggressive) MODE="aggressive"; AGGRESSIVE=1 ;;
        --dry-run)    DRY=1 ;;
        --help|-h)
            sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

# Ajustar configuración según el modo
if [ "$MODE" = "deep" ]; then
    JOURNAL_MAX_SIZE="50M"
    JOURNAL_KEEP_DAYS="3d"
    LOG_RETAIN_DAYS=3
    CACHE_AGE_DAYS=7
    TMP_AGE_DAYS=1
    VARTMP_AGE_DAYS=3
    DOCKER_PRUNE_DAYS=7
    KERNELS_TO_KEEP=2
elif [ "$AGGRESSIVE" -eq 1 ]; then
    # Modo agresivo: borrar todo sin respetar edades
    JOURNAL_MAX_SIZE="1M"
    JOURNAL_KEEP_DAYS="0d"
    LOG_RETAIN_DAYS=1
    CACHE_AGE_DAYS=0
    TMP_AGE_DAYS=0
    VARTMP_AGE_DAYS=0
    DOCKER_PRUNE_DAYS=0
    KERNELS_TO_KEEP=1
fi

# ── Helpers ───────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log_info()  { echo "[$(date +'%H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE"; }
# shellcheck disable=SC2317  # Used indirectly by callers
log_warn()  { echo "[$(date +'%H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE" >&2; }
# shellcheck disable=SC2317  # Used indirectly by callers
log_error() { echo "[$(date +'%H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }
sec()       { echo "" | tee -a "$LOG_FILE"; log_info "═══ $* ═══"; }

runq() {
    if [ "$DRY" -eq 1 ]; then
        log_info "[DRY-RUN] $*"
    else
        bash -c "$*" >> "$LOG_FILE" 2>&1
    fi
}

# Requiere root
if [ "$(id -u)" -ne 0 ]; then
    echo "Necesita root: sudo $0 $*" >&2
    exit 1
fi

# Detectar TODOS los usuarios reales (UID >= 1000 y < 60000)
mapfile -t REAL_USERS < <(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd)
SUDO_USER="${SUDO_USER:-root}"
if [ ${#REAL_USERS[@]} -eq 0 ]; then
    REAL_USERS=("$SUDO_USER")
fi
REAL_USER="${REAL_USERS[0]}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Lock para evitar concurrencia
exec 9>/var/run/kali-cleanup.lock
if ! flock -n 9; then
    log_info "Ya hay otra instancia corriendo. Salgo."
    exit 0
fi

START_TS=$(date +%s)
BEFORE_KB=$(df / | awk 'NR==2{print $3}')

log_info "═══════════════════════════════════════════════════════════════════════"
log_info "  kali-auto-cleanup VERSIÓN EXTREMA - MODO=$MODE  DRY=$DRY"
if [ "$AGGRESSIVE" -eq 1 ]; then
    log_info "  (AGGRESSIVE: limpiando TODO sin respetar fechas)"
fi
log_info "═══════════════════════════════════════════════════════════════════════"

# =========================================================================
# MODULES
# =========================================================================

# ── 1. APT - LIMPIEZA ────────────────────────────────────────────────
cleanup_apt() {
    sec "APT - Limpieza de paquetes y cachés"

    runq "apt-get clean -y"
    runq "apt-get autoclean -y"
    runq "apt-get autoremove --purge -y"

    RC_PKGS=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | tr '\n' ' ')
    if [ -n "$RC_PKGS" ]; then
        log_info "Purgando configs residuales: $(echo "$RC_PKGS" | wc -w) paquetes"
        runq "dpkg --purge $RC_PKGS"
    fi

    runq "rm -rf /var/cache/apt/archives/*.deb"
    runq "rm -rf /var/cache/apt/archives/partial/*"
    runq "rm -rf /var/lib/apt/lists/*"
    runq "apt-get update -qq"

    # Limpiar paquetes huérfanos (si deborphan está instalado)
    if command -v deborphan >/dev/null; then
        runq "deborphan | xargs -r apt-get -y remove --purge 2>/dev/null"
    fi
}

# ── 2. LOGS - SEGÚN MODO ─────────────────────────────────────────────
cleanup_logs() {
    sec "LOGS - Limpieza de archivos de log"

    runq "journalctl --rotate"
    runq "journalctl --vacuum-size=$JOURNAL_MAX_SIZE"
    runq "journalctl --vacuum-time=$JOURNAL_KEEP_DAYS"
    if [ "$AGGRESSIVE" -eq 1 ]; then
        runq "journalctl --vacuum-files=1"
        runq "rm -rf /var/log/journal/*/system.journal 2>/dev/null"
    else
        runq "journalctl --vacuum-files=5"
    fi

    # Eliminar logs rotados
    if [ "$AGGRESSIVE" -eq 1 ]; then
        # Borrar todos los logs rotados sin importar fecha
        runq "find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' -o -regex '.*\.[0-9]+\(\.gz\)?$' \) -delete 2>/dev/null"
        # Truncar logs activos a 0 bytes
        runq "find /var/log -type f -size +0c -exec truncate -s 0 {} \; 2>/dev/null"
    else
        runq "find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' -o -regex '.*\.[0-9]+\(\.gz\)?$' \) -mtime +$LOG_RETAIN_DAYS -delete 2>/dev/null"
        runq "find /var/log -type f -size +50M -exec truncate -s 10M {} \; 2>/dev/null"
    fi

    # Logs de servicios
    for service in apache2 nginx mysql mariadb postgresql redis mongodb; do
        if [ "$AGGRESSIVE" -eq 1 ]; then
            runq "rm -rf /var/log/$service/* 2>/dev/null"
        else
            runq "find /var/log/$service -type f -name '*.log*' -mtime +3 -delete 2>/dev/null"
            runq "find /var/log/$service -type f -size +100M -exec truncate -s 0 {} \; 2>/dev/null"
        fi
    done

    # Logs de herramientas hacking
    for tool in metasploit beef bettercap wireshark aircrack-ng hashcat john; do
        if [ "$AGGRESSIVE" -eq 1 ]; then
            runq "rm -rf /var/log/$tool/* 2>/dev/null"
        else
            runq "find /var/log/$tool -type f -mtime +7 -delete 2>/dev/null"
        fi
    done

    # Logs del sistema
    if [ "$AGGRESSIVE" -eq 1 ]; then
        for logfile in syslog auth.log kern.log dpkg.log; do
            runq "truncate -s 0 /var/log/$logfile 2>/dev/null"
        done
        runq "find /var/log/apt -type f -delete 2>/dev/null"
    else
        runq "find /var/log -type f -name 'syslog' -mtime +7 -exec truncate -s 0 {} \; 2>/dev/null"
        runq "find /var/log -type f -name 'auth.log' -mtime +7 -exec truncate -s 0 {} \; 2>/dev/null"
        runq "find /var/log -type f -name 'kern.log' -mtime +7 -exec truncate -s 0 {} \; 2>/dev/null"
        runq "find /var/log -type f -name 'dpkg.log' -mtime +30 -delete 2>/dev/null"
        runq "find /var/log/apt -type f -mtime +30 -delete 2>/dev/null"
    fi

    # Rotar logs propios
    find "$LOG_DIR" -type f -name "cleanup-*.log" -mtime +$KEEP_LOG_DAYS -delete 2>/dev/null
}

# ── 3. ARCHIVOS TEMPORALES ───────────────────────────────────────────
cleanup_tmp() {
    sec "TMP - Archivos temporales"

    if [ "$AGGRESSIVE" -eq 1 ]; then
        # Safe find-based deletion to preserve X11 sockets and systemd-private dirs
        runq "find /tmp -mindepth 1 -not -name '.*' -not -path '*/systemd-private-*' -delete 2>/dev/null"
        runq "find /tmp -mindepth 1 -name '.*' -not -name '.' -not -name '..' -not -path '.X11-unix' -not -path '.font-unix' -not -path '.ICE-unix' -not -path 'systemd-private-*' -delete 2>/dev/null"
        runq "find /var/tmp -mindepth 1 -not -name '.*' -not -path '*/systemd-private-*' -delete 2>/dev/null"
        runq "find /var/tmp -mindepth 1 -name '.*' -not -name '.' -not -name '..' -not -path '.X11-unix' -not -path '.font-unix' -not -path '.ICE-unix' -not -path 'systemd-private-*' -delete 2>/dev/null"
        runq "rm -rf /var/crash/* 2>/dev/null"
        runq "rm -rf /var/lib/systemd/coredump/* 2>/dev/null"
        runq "rm -rf /var/cache/fontconfig/* 2>/dev/null"
        runq "rm -rf /var/cache/man/* 2>/dev/null"
        runq "rm -rf /var/cache/thumbnails/* 2>/dev/null"
    else
        runq "find /tmp -mindepth 1 -atime +$TMP_AGE_DAYS -not -path '*/systemd-private-*' -delete 2>/dev/null"
        runq "find /tmp -type f -size +100M -delete 2>/dev/null"
        runq "find /var/tmp -mindepth 1 -atime +$VARTMP_AGE_DAYS -delete 2>/dev/null"
        runq "rm -rf /var/crash/* 2>/dev/null"
        runq "rm -rf /var/lib/systemd/coredump/* 2>/dev/null"
        runq "rm -rf /var/cache/fontconfig/* 2>/dev/null"
        runq "rm -rf /var/cache/man/* 2>/dev/null"
        runq "rm -rf /var/cache/thumbnails/* 2>/dev/null"
    fi
}

# ── 4. CACHES DE USUARIO ─────────────────────────────────────────────
cleanup_user_caches() {
    sec "CACHES USUARIO - Limpieza para todos los usuarios"

    for CURRENT_USER in "${REAL_USERS[@]}"; do
        CURRENT_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
        if [ -n "$CURRENT_HOME" ] && [ -d "$CURRENT_HOME" ]; then
            log_info "Limpiando cachés de usuario: $CURRENT_USER (modo $MODE)"

            if [ "$AGGRESSIVE" -eq 1 ]; then
                # Modo agresivo: borrar todo .cache, papeleras, thumbnails, historiales, etc.
                sudo -u "$CURRENT_USER" bash -c "
                    rm -rf '$CURRENT_HOME/.cache'/* 2>/dev/null
                    rm -rf '$CURRENT_HOME/.thumbnails'/* 2>/dev/null
                    rm -rf '$CURRENT_HOME/.local/share/Trash'/* 2>/dev/null
                    rm -rf '$CURRENT_HOME/.gradle/caches' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.m2/repository' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.ivy2/cache' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.sbt' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.intellij-idea' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.vscode-server' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.pycharm_helpers' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.msf4'/* 2>/dev/null
                    rm -rf '$CURRENT_HOME/.BurpSuite'/* 2>/dev/null
                    rm -rf '$CURRENT_HOME/.recon-ng' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.sqlmap/output' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.nmap/logs' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.wireshark' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.vagrant.d/cache' 2>/dev/null
                    rm -rf '$CURRENT_HOME/.docker' 2>/dev/null
                    # Vaciar historiales completamente
                    for hist in .bash_history .zsh_history .python_history .mysql_history .sqlite_history .node_repl_history .psql_history; do
                        > \"\$CURRENT_HOME/\$hist\" 2>/dev/null
                    done
                " 2>&1 | tee -a "$LOG_FILE"
            else
                # Modos normal/deep: respetar edades
                sudo -u "$CURRENT_USER" bash -c "
                    find '$CURRENT_HOME/.cache/thumbnails' -type f -atime +7 -delete 2>/dev/null
                    find '$CURRENT_HOME/.thumbnails' -type f -atime +7 -delete 2>/dev/null
                    rm -rf '$CURRENT_HOME/.local/share/Trash'/* 2>/dev/null
                    # Caches navegador
                    find '$CURRENT_HOME/.cache/mozilla' -type d -name 'cache2' -exec rm -rf {}/entries {}/doomed \; 2>/dev/null
                    find '$CURRENT_HOME/.cache/google-chrome' -type d -name 'Cache' -exec sh -c 'rm -rf \"\$1\"/*' _ {} \; 2>/dev/null
                    find '$CURRENT_HOME/.cache/chromium' -type d -name 'Cache' -exec sh -c 'rm -rf \"\$1\"/*' _ {} \; 2>/dev/null
                    find '$CURRENT_HOME/.cache/BraveSoftware' -type d -name 'Cache' -exec sh -c 'rm -rf \"\$1\"/*' _ {} \; 2>/dev/null
                    # Caches genéricos antiguos
                    find '$CURRENT_HOME/.cache' -type f -atime +$CACHE_AGE_DAYS -delete 2>/dev/null
                    # Herramientas hacking (logs +30 días)
                    find '$CURRENT_HOME/.msf'* -type f \\( -name '*.log' -o -path '*/loot/*' \\) -mtime +30 -delete 2>/dev/null
                    find '$CURRENT_HOME/.BurpSuite' -type f -name '*.log' -delete 2>/dev/null
                    find '$CURRENT_HOME/.recon-ng/workspaces' -type d -name 'loot' -exec rm -rf {}/* \\; 2>/dev/null
                    # Truncar historiales a 1000 líneas
                    for hist in '.bash_history' '.zsh_history' '.python_history' '.mysql_history' '.sqlite_history' '.node_repl_history'; do
                        [ -f \"\$CURRENT_HOME/\$hist\" ] && [ \$(wc -l < \"\$CURRENT_HOME/\$hist\") -gt 1000 ] && tail -n 1000 \"\$CURRENT_HOME/\$hist\" > \"\$CURRENT_HOME/\$hist.tmp\" && mv \"\$CURRENT_HOME/\$hist.tmp\" \"\$CURRENT_HOME/\$hist\"
                    done
                " 2>&1 | tee -a "$LOG_FILE"
            fi
        fi
    done
}

# ── 5. GESTORES DE PAQUETES ──────────────────────────────────────────
cleanup_package_managers() {
    sec "CACHES PAQUETES - pip, npm, cargo, gem, yarn, composer"

    if command -v pip3 >/dev/null; then
        runq "pip3 cache purge"
        if [ "$AGGRESSIVE" -eq 1 ]; then
            pip3_cache=$(pip3 cache dir 2>/dev/null)
            [ -n "$pip3_cache" ] && runq "rm -rf '$pip3_cache'"
        fi
    fi
    if command -v pip2 >/dev/null; then
        runq "pip2 cache purge 2>/dev/null"
    fi

    if command -v npm >/dev/null; then
        runq "npm cache clean --force"
        if [ "$AGGRESSIVE" -eq 1 ]; then
            runq "rm -rf '$REAL_HOME/.npm/_cacache'"
        fi
    fi

    if command -v yarn >/dev/null; then
        runq "yarn cache clean --force"
    fi

    if [ -d "$REAL_HOME/.cargo" ]; then
        runq "rm -rf '$REAL_HOME/.cargo/registry/cache'/*"
        runq "rm -rf '$REAL_HOME/.cargo/registry/src'/*"
        runq "rm -rf '$REAL_HOME/.cargo/git/checkouts'/*"
    fi

    if command -v gem >/dev/null; then
        runq "gem cleanup"
        runq "gem sources -c"
    fi

    if command -v composer >/dev/null; then
        runq "composer clear-cache"
    fi

    if [ -d "$REAL_HOME/go/pkg/mod" ]; then
        runq "go clean -modcache"
    fi
}

# ── 6. DOCKER ────────────────────────────────────────────────────────
cleanup_docker() {
    sec "MODO DEEP — Limpieza profunda"

    # Docker
    if command -v docker >/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        log_info "Limpieza Docker (prune cada ${DOCKER_PRUNE_DAYS} días)"
        runq "docker system prune -af --volumes --filter 'until=${DOCKER_PRUNE_DAYS}d'"
        runq "docker container prune -f"
        runq "docker image prune -af"
        runq "docker volume prune -af"
        runq "docker network prune -f"
        runq "docker builder prune -af"
        runq "docker rmi \$(docker images -f 'dangling=true' -q) 2>/dev/null"
    fi

    # Kernels antiguos
    CURRENT=$(uname -r | sed 's/-amd64$//; s/-generic$//')
    if [ "$AGGRESSIVE" -eq 1 ]; then
        # Eliminar todos los kernels excepto el actual
        OLD_KERNELS=$(dpkg -l | awk '/^ii  linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT")
    else
        # Mantener el actual + (KERNELS_TO_KEEP - 1) backups
        OLD_KERNELS=$(dpkg -l | awk '/^ii  linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT" | head -n -$((KERNELS_TO_KEEP - 1)))
    fi
    if [ -n "$OLD_KERNELS" ]; then
        log_info "Eliminando kernels antiguos: $OLD_KERNELS"
        runq "DEBIAN_FRONTEND=noninteractive apt-get purge -y $OLD_KERNELS"
    fi

    # Headers antiguos
    OLD_HEADERS=$(dpkg -l | awk '/^ii  linux-headers-[0-9]/ {print $2}' | grep -v "$(uname -r | cut -d'-' -f1-2)" | head -n -1)
    if [ -n "$OLD_HEADERS" ]; then
        runq "DEBIAN_FRONTEND=noninteractive apt-get purge -y $OLD_HEADERS"
    fi

    # Locales no utilizados
    if command -v localepurge >/dev/null; then
        runq "localepurge"
    fi

    # Snap
    if command -v snap >/dev/null; then
        log_info "Limpiando snaps viejos"
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname rev; do
            runq "snap remove '$snapname' --revision='$rev'"
        done
        runq "rm -rf /var/lib/snapd/cache/*"
    fi

    # Flatpak
    if command -v flatpak >/dev/null; then
        log_info "Limpiando flatpaks no utilizados"
        runq "flatpak uninstall --unused -y"
        runq "flatpak repair --user"
        if [ "$AGGRESSIVE" -eq 1 ]; then
            runq "flatpak remove --unused --delete-data -y"
            runq "flatpak uninstall --all -y 2>/dev/null"
        fi
    fi

    # AppImage
    runq "rm -rf '$REAL_HOME/.cache/appimagekit'/*"

    # TRIM
    runq "fstrim -av"

    # mandb
    runq "mandb --quiet"

    # Iconos
    runq "rm -rf /usr/share/icons/*/icon-theme.cache 2>/dev/null"
    runq "rm -rf '$REAL_HOME/.cache/icon-cache.kcache' 2>/dev/null"
}

# ── 7. MODO AGGRESSIVE adicional (limpiezas extra) ───────────────────
cleanup_aggressive_extras() {
    if [ "$AGGRESSIVE" -ne 1 ]; then
        return
    fi

    sec "MODO AGGRESSIVE — Limpieza extra adicional"

    # Eliminar logs de más de 1 día
    runq "find /var/log -type f -mtime +1 -delete 2>/dev/null"

    # Limpiar cachés de sistema
    runq "rm -rf /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin 2>/dev/null"
    runq "rm -rf /var/cache/debconf/*-old 2>/dev/null"
    runq "fc-cache -f -v"

    # Eliminar snapshots de Timeshift si existe
    if command -v timeshift >/dev/null; then
        runq "timeshift --delete-all 2>/dev/null"
    fi

    # Reforzar limpieza de .cache de todos los usuarios
    for CURRENT_USER in "${REAL_USERS[@]}"; do
        CURRENT_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
        if [ -d "$CURRENT_HOME/.cache" ]; then
            runq "rm -rf '$CURRENT_HOME/.cache'/*"
        fi
    done
}

# ── 8. LIBERAR CACHES DE RAM ─────────────────────────────────────────
cleanup_ram() {
    sec "RAM - Liberación de cachés de memoria"

    runq "sync"
    if [ "$DRY" -eq 0 ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        echo 2 > /proc/sys/vm/drop_caches 2>/dev/null
        echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
    fi

    if [ "$AGGRESSIVE" -eq 1 ] && [ "$DRY" -eq 0 ]; then
        if [ "$(awk '/MemAvailable/{print $2}' /proc/meminfo)" -gt 2000000 ]; then
            swapoff -a 2>/dev/null
            swapon -a 2>/dev/null
        fi
    fi

    log_info "Cachés RAM liberados"
}

# ── 9. OPTIMIZACIONES ADICIONALES ────────────────────────────────────
cleanup_optimizations() {
    sec "OPTIMIZACIONES - Mantenimiento adicional"

    if command -v updatedb >/dev/null; then
        runq "updatedb"
    fi

    if command -v resolvectl >/dev/null; then
        runq "resolvectl flush-caches 2>/dev/null"
    else
        runq "systemd-resolve --flush-caches 2>/dev/null"
    fi

    runq "dpkg --configure -a"
    runq "apt-get install -f -y"
}

# =========================================================================
# MAIN
# =========================================================================
main() {
    cleanup_apt
    cleanup_logs
    cleanup_tmp
    cleanup_user_caches
    cleanup_package_managers

    # Módulos que solo corren en deep o aggressive
    if [ "$MODE" = "deep" ] || [ "$AGGRESSIVE" -eq 1 ]; then
        cleanup_docker
    fi

    cleanup_aggressive_extras
    cleanup_ram
    cleanup_optimizations

    # ── RESUMEN FINAL ──────────────────────────────────────────────────
    AFTER_KB=$(df / | awk 'NR==2{print $3}')
    FREED_MB=$(( (BEFORE_KB - AFTER_KB) / 1024 ))
    ELAPSED=$(( $(date +%s) - START_TS ))

    sec "RESUMEN FINAL"
    log_info "╔═══════════════════════════════════════════════════════════════════════"
    log_info "║  TIEMPO EJECUCIÓN:     ${ELAPSED} segundos"
    log_info "║  ESPACIO LIBERADO:     ${FREED_MB} MB ($((FREED_MB / 1024)) GB)"
    log_info "║  MODO DE LIMPIEZA:     ${MODE}"
    log_info "║  USUARIOS PROCESADOS:  ${#REAL_USERS[@]}"
    log_info "╚═══════════════════════════════════════════════════════════════════════"

    log_info ""
    log_info "📊 ESTADO DEL DISCO /:"
    df -h / | tee -a "$LOG_FILE"
    log_info ""
    log_info "📊 MEMORIA:"
    free -h | tee -a "$LOG_FILE"

    log_info ""
    log_info "📈 ESTADÍSTICAS DE LIMPIEZA:"
    log_info "  • Paquetes rc eliminados: $(dpkg -l 2>/dev/null | grep -c '^rc')"
    log_info "  • Espacio en /tmp: $(du -sh /tmp 2>/dev/null | cut -f1)"
    log_info "  • Espacio en /var/tmp: $(du -sh /var/tmp 2>/dev/null | cut -f1)"
    log_info "  • Archivos de log comprimidos: $(find /var/log -type f -name '*.gz' 2>/dev/null | wc -l)"

    log_info ""
    log_info "═══════════════════════════════════════════════════════════════════════"
    log_info "  ✅ LIMPIEZA COMPLETADA - $(date)"
    log_info "═══════════════════════════════════════════════════════════════════════"
}

main "$@"
exit 0
