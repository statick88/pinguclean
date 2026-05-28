#!/usr/bin/env bash
#
# kali-auto-cleanup.sh — Mantenimiento automático de Kali Linux (VERSIÓN EXTREMA)
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
set -u
umask 022

# ── Config ────────────────────────────────────────────────────────────
LOG_DIR="/var/log/kali-cleanup"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y%m%d_%H%M%S).log"
KEEP_LOG_DAYS=14
JOURNAL_MAX_SIZE="50M"          # Reducido de 100M
JOURNAL_KEEP_DAYS="3d"          # Reducido de 7d
CACHE_AGE_DAYS=7                # Reducido de 14
TMP_AGE_DAYS=1                  # Reducido de 2
VARTMP_AGE_DAYS=3               # Reducido de 7
DOCKER_PRUNE_DAYS=7             # Reducido de 30
KERNELS_TO_KEEP=2               # Mantener solo 2 kernels

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

# Detectar TODOS los usuarios reales
REAL_USERS=($(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd))
REAL_USER="${REAL_USERS[0]}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Lock para evitar concurrencia
exec 9>/var/run/kali-cleanup.lock
if ! flock -n 9; then
    log "Ya hay otra instancia corriendo. Salgo."
    exit 0
fi

START_TS=$(date +%s)
BEFORE_KB=$(df / | awk 'NR==2{print $3}')

log "═══════════════════════════════════════════════════════════════════════"
log "  kali-auto-cleanup VERSIÓN EXTREMA - MODO=$MODE  DRY=$DRY"
log "═══════════════════════════════════════════════════════════════════════"

# =========================================================================
# 1. APT - LIMPIEZA EXTREMA
# =========================================================================
sec "APT - Limpieza extrema de paquetes y cachés"

# Limpieza básica
runq "apt-get clean -y"
runq "apt-get autoclean -y"
runq "apt-get autoremove --purge -y"

# Purgar configs residuales (rc)
RC_PKGS=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' | tr '\n' ' ')
if [ -n "$RC_PKGS" ]; then
    log "Purgando configs residuales: $(echo $RC_PKGS | wc -w) paquetes"
    runq "dpkg --purge $RC_PKGS"
fi

# Limpiar cachés de APT adicionales
runq "rm -rf /var/cache/apt/archives/*.deb"
runq "rm -rf /var/cache/apt/archives/partial/*"
runq "rm -rf /var/lib/apt/lists/* --delete"
runq "apt-get update -qq"

# Limpiar paquetes huérfanos (dependencias no utilizadas)
runq "deborphan | xargs apt-get -y remove --purge 2>/dev/null"

# Limpiar configuración de paquetes desinstalados
runq "dpkg -l | grep '^rc' | awk '{print $2}' | xargs dpkg --purge 2>/dev/null"

# =========================================================================
# 2. LOGS - LIMPIEZA EXTREMA
# =========================================================================
sec "LOGS - Limpieza extrema de archivos de log"

# Journalctl
runq "journalctl --rotate"
runq "journalctl --vacuum-size=$JOURNAL_MAX_SIZE"
runq "journalctl --vacuum-time=$JOURNAL_KEEP_DAYS"
runq "journalctl --vacuum-files=5"

# Eliminar logs rotados antiguos (más agresivo)
runq "find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.2' -o -name '*.3' -o -regex '.*\.[0-9]+\(\.gz\)?$' \) -mtime +$JOURNAL_KEEP_DAYS%d -delete 2>/dev/null"

# Truncar logs activos grandes (reducir tamaño)
runq "find /var/log -type f -size +50M -exec truncate -s 10M {} \; 2>/dev/null"

# Eliminar logs de servicios específicos
for service in apache2 nginx mysql mariadb postgresql redis mongodb; do
    runq "find /var/log/$service -type f -name '*.log*' -mtime +3 -delete 2>/dev/null"
    runq "find /var/log/$service -type f -size +100M -exec truncate -s 0 {} \; 2>/dev/null"
done

# Limpiar logs de herramientas de hacking
for tool in metasploit beef bettercap wireshark aircrack-ng hashcat john; do
    runq "find /var/log/$tool -type f -mtime +7 -delete 2>/dev/null"
done

# Limpiar logs de sistema antiguos
runq "find /var/log -type f -name 'syslog' -mtime +7 -exec truncate -s 0 {} \;"
runq "find /var/log -type f -name 'auth.log' -mtime +7 -exec truncate -s 0 {} \;"
runq "find /var/log -type f -name 'kern.log' -mtime +7 -exec truncate -s 0 {} \;"
runq "find /var/log -type f -name 'dpkg.log' -mtime +30 -delete 2>/dev/null"

# Limpiar logs de apt
runq "find /var/log/apt -type f -mtime +30 -delete 2>/dev/null"

# Rotar y limpiar nuestros propios logs
find "$LOG_DIR" -type f -name "cleanup-*.log" -mtime +$KEEP_LOG_DAYS -delete 2>/dev/null

# =========================================================================
# 3. ARCHIVOS TEMPORALES - LIMPIEZA EXTREMA
# =========================================================================
sec "TMP - Limpieza extrema de archivos temporales"

# /tmp - más agresivo
runq "find /tmp -mindepth 1 -atime +$TMP_AGE_DAYS -not -path '*/systemd-private-*' -delete 2>/dev/null"
runq "find /tmp -type f -size +100M -delete 2>/dev/null"

# /var/tmp
runq "find /var/tmp -mindepth 1 -atime +$VARTMP_AGE_DAYS -delete 2>/dev/null"

# Crash dumps y coredumps
runq "rm -rf /var/crash/* 2>/dev/null"
runq "rm -rf /var/lib/systemd/coredump/* 2>/dev/null"
runq "rm -rf /var/log/journal/*/system.journal 2>/dev/null"

# Limpiar cachés de kernel
runq "rm -rf /var/cache/fontconfig/* 2>/dev/null"
runq "rm -rf /var/cache/man/* 2>/dev/null"

# Limpiar thumbnails del sistema
runq "rm -rf /var/cache/thumbnails/* 2>/dev/null"

# =========================================================================
# 4. CACHES DE USUARIO - LIMPIEZA EXTREMA
# =========================================================================
sec "CACHES USUARIO - Limpieza extrema para todos los usuarios"

for CURRENT_USER in "${REAL_USERS[@]}"; do
    CURRENT_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
    
    if [ -n "$CURRENT_HOME" ] && [ -d "$CURRENT_HOME" ]; then
        log "Limpiando cachés de usuario: $CURRENT_USER"
        
        sudo -u "$CURRENT_USER" bash -c "
            # Thumbnails
            rm -rf '$CURRENT_HOME/.cache/thumbnails'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.thumbnails'/* 2>/dev/null
            
            # Papelera
            rm -rf '$CURRENT_HOME/.local/share/Trash'/* 2>/dev/null
            
            # Caches de navegador
            rm -rf '$CURRENT_HOME/.cache/mozilla/firefox'/*/cache2/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.cache/google-chrome'/*/Cache/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.cache/chromium'/*/Cache/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.cache/BraveSoftware'/*/Cache/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.cache/microsoft-edge'/*/Cache/* 2>/dev/null
            
            # Caches genéricos
            find '$CURRENT_HOME/.cache' -type f -atime +$CACHE_AGE_DAYS -delete 2>/dev/null
            find '$CURRENT_HOME/.cache' -type d -empty -delete 2>/dev/null
            
            # Limpiar historial de ubicaciones recientes
            rm -f '$CURRENT_HOME/.recently-used' 2>/dev/null
            rm -f '$CURRENT_HOME/.local/share/recently-used.xbel' 2>/dev/null
            
            # Limpiar caches de desarrollo
            rm -rf '$CURRENT_HOME/.gradle/caches'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.m2/repository'/*/ 2>/dev/null
            rm -rf '$CURRENT_HOME/.ivy2/cache'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.sbt'/*/cache/* 2>/dev/null
            
            # Limpiar caches de IDE
            rm -rf '$CURRENT_HOME/.intellij-idea'/*/system/caches/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.vscode-server'/*/cache/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.pycharm_helpers'/*/cache/* 2>/dev/null
            
            # Limpiar logs de herramientas hacking (más agresivo)
            rm -rf '$CURRENT_HOME/.msf4/logs'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.msf4/loot'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.msf4/local/*' 2>/dev/null
            rm -rf '$CURRENT_HOME/.BurpSuite'/*.log 2>/dev/null
            rm -rf '$CURRENT_HOME/.recon-ng/workspaces'/*/loot/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.sqlmap/output'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.nmap/logs'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.wireshark'/* 2>/dev/null
            
            # Limpiar caches de virtualización
            rm -rf '$CURRENT_HOME/.vagrant.d/cache'/* 2>/dev/null
            rm -rf '$CURRENT_HOME/.docker'/*/cache/* 2>/dev/null
            
            # Truncar historiales (más agresivo)
            for hist in '.bash_history' '.zsh_history' '.python_history' '.lesshst' '.mysql_history' '.sqlite_history' '.node_repl_history' '.psql_history'; do
                if [ -f \"\$CURRENT_HOME/\$hist\" ]; then
                    tail -n 1000 \"\$CURRENT_HOME/\$hist\" > \"\$CURRENT_HOME/\$hist.tmp\" 2>/dev/null
                    mv \"\$CURRENT_HOME/\$hist.tmp\" \"\$CURRENT_HOME/\$hist\" 2>/dev/null
                fi
            done
            
            # Limpiar bashrc y zshrc de líneas comentadas
            sed -i '/^#/d' '$CURRENT_HOME/.bashrc' 2>/dev/null
            sed -i '/^$/d' '$CURRENT_HOME/.bashrc' 2>/dev/null
        " 2>&1 | tee -a "$LOG_FILE"
    fi
done

# =========================================================================
# 5. GESTORES DE PAQUETES - LIMPIEZA EXTREMA
# =========================================================================
sec "CACHES PAQUETES - pip, npm, cargo, gem, yarn, composer"

# Pip
if command -v pip3 >/dev/null; then
    runq "pip3 cache purge"
    runq "pip3 cache dir | xargs rm -rf"
fi

# Pip2 (si existe)
if command -v pip2 >/dev/null; then
    runq "pip2 cache purge 2>/dev/null"
fi

# NPM
if command -v npm >/dev/null; then
    runq "npm cache clean --force"
    runq "rm -rf ~/.npm/_cacache"
fi

# Yarn
if command -v yarn >/dev/null; then
    runq "yarn cache clean --force"
fi

# Cargo (Rust) - más agresivo
if [ -d "$REAL_HOME/.cargo" ]; then
    runq "rm -rf $REAL_HOME/.cargo/registry/cache/*"
    runq "rm -rf $REAL_HOME/.cargo/registry/src/*"
    runq "rm -rf $REAL_HOME/.cargo/git/checkouts/*"
fi

# Ruby gems
if command -v gem >/dev/null; then
    runq "gem cleanup"
    runq "gem sources -c"
fi

# Composer (PHP)
if command -v composer >/dev/null; then
    runq "composer clear-cache"
fi

# Go modules
if [ -d "$REAL_HOME/go/pkg/mod" ]; then
    runq "go clean -modcache"
fi

# =========================================================================
# 6. MODO DEEP - LIMPIEZA SEMANAL
# =========================================================================
if [ "$MODE" = "deep" ] || [ "$AGGRESSIVE" -eq 1 ]; then
    sec "MODO DEEP — Limpieza semanal profunda"

    # Docker - más agresivo
    if command -v docker >/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        log "Limpieza profunda de Docker"
        runq "docker system prune -af --volumes --filter 'until=${DOCKER_PRUNE_DAYS}h'"
        runq "docker container prune -f"
        runq "docker image prune -af"
        runq "docker volume prune -af"
        runq "docker network prune -f"
        runq "docker builder prune -af"
        
        # Eliminar contenedores detenidos
        runq "docker rm $(docker ps -aq) 2>/dev/null"
        # Eliminar imágenes dangling
        runq "docker rmi $(docker images -f 'dangling=true' -q) 2>/dev/null"
    fi

    # Kernels antiguos (más agresivo)
    CURRENT=$(uname -r | sed 's/-amd64$//; s/-generic$//')
    OLD_KERNELS=$(dpkg -l | awk '/^ii  linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT" | head -n -$((KERNELS_TO_KEEP - 1)))
    if [ -n "$OLD_KERNELS" ]; then
        log "Eliminando kernels antiguos: $OLD_KERNELS"
        runq "DEBIAN_FRONTEND=noninteractive apt-get purge -y $OLD_KERNELS"
    fi

    # Limpiar headers antiguos
    OLD_HEADERS=$(dpkg -l | awk '/^ii  linux-headers-[0-9]/ {print $2}' | grep -v "$(uname -r | cut -d'-' -f1-2)" | head -n -1)
    if [ -n "$OLD_HEADERS" ]; then
        runq "DEBIAN_FRONTEND=noninteractive apt-get purge -y $OLD_HEADERS"
    fi

    # Locales no utilizados
    if command -v localepurge >/dev/null; then
        runq "localepurge"
    fi

    # Snap - más agresivo
    if command -v snap >/dev/null; then
        log "Limpiando snaps viejos"
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname rev; do
            runq "snap remove '$snapname' --revision='$rev'"
        done
        # Limpiar caché de snap
        runq "rm -rf /var/lib/snapd/cache/*"
    fi

    # Flatpak - más agresivo
    if command -v flatpak >/dev/null; then
        log "Limpiando flatpaks no utilizados"
        runq "flatpak uninstall --unused -y"
        runq "flatpak repair --user"
        runq "flatpak remove --unused --delete-data -y"
    fi

    # AppImage (limpiar cachés)
    runq "rm -rf ~/.cache/appimagekit/*"

    # TRIM disco
    runq "fstrim -av"

    # Reconstruir base de datos man
    runq "mandb --quiet"

    # Limpiar cachés de iconos y temas
    runq "rm -rf /usr/share/icons/*/icon-theme.cache 2>/dev/null"
    runq "rm -rf ~/.cache/icon-cache.kcache 2>/dev/null"
fi

# =========================================================================
# 7. MODO AGGRESSIVE - LIMPIEZA MENSUAL EXTREMA
# =========================================================================
if [ "$AGGRESSIVE" -eq 1 ]; then
    sec "MODO AGGRESSIVE — Limpieza mensual extrema (¡MÁXIMA LIMPIEZA!)"

    # Eliminar logs de más de 30 días
    runq "find /var/log -type f -mtime +30 -delete 2>/dev/null"
    
    # Limpiar completamente /tmp
    runq "rm -rf /tmp/* 2>/dev/null"
    runq "rm -rf /tmp/.* 2>/dev/null"
    
    # Limpiar completamente /var/tmp
    runq "rm -rf /var/tmp/* 2>/dev/null"
    
    # Limpiar cachés de sistema
    runq "rm -rf /var/cache/apt/pkgcache.bin"
    runq "rm -rf /var/cache/apt/srcpkgcache.bin"
    runq "rm -rf /var/cache/debconf/*-old"
    
    # Limpiar cachés de fuentes
    runq "fc-cache -f -v"
    
    # Limpiar journals antiguos completamente
    runq "journalctl --rotate"
    runq "journalctl --vacuum-time=2d"
    
    # Limpiar cachés de paquetes flatpak
    if command -v flatpak >/dev/null; then
        runq "flatpak uninstall --all -y 2>/dev/null"
    fi
    
    # Limpiar snapshots de Timeshift (si existe)
    if command -v timeshift >/dev/null; then
        runq "timeshift --delete-all 2>/dev/null"
    fi
    
    # Limpiar completamente .cache de todos los usuarios
    for CURRENT_USER in "${REAL_USERS[@]}"; do
        CURRENT_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
        if [ -d "$CURRENT_HOME/.cache" ]; then
            runq "rm -rf $CURRENT_HOME/.cache/*"
        fi
    done
fi

# =========================================================================
# 8. LIBERAR CACHES DE RAM Y MEMORIA
# =========================================================================
sec "RAM - Liberación de cachés de memoria"

runq "sync"

# Liberar caches de página, dentries e inodos
if [ "$DRY" -eq 0 ]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo 2 > /proc/sys/vm/drop_caches 2>/dev/null
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
fi

# Liberar swap (si está habilitado)
if [ "$AGGRESSIVE" -eq 1 ] && [ "$DRY" -eq 0 ]; then
    swapoff -a 2>/dev/null
    swapon -a 2>/dev/null
fi

log "Cachés RAM liberados"

# =========================================================================
# 9. OPTIMIZACIONES ADICIONALES
# =========================================================================
sec "OPTIMIZACIONES - Mantenimiento adicional del sistema"

# Reconstruir base de datos locate
if command -v updatedb >/dev/null; then
    runq "updatedb"
fi

# Limpiar cachés de DNS
runq "systemd-resolve --flush-caches 2>/dev/null"

# Limpiar historial de comandos del sistema
runq "history -c 2>/dev/null"

# Optimizar bases de datos de paquetes
runq "dpkg --configure -a"
runq "apt-get install -f -y"

# =========================================================================
# 10. RESUMEN FINAL Y ESTADÍSTICAS
# =========================================================================
AFTER_KB=$(df / | awk 'NR==2{print $3}')
FREED_MB=$(( (BEFORE_KB - AFTER_KB) / 1024 ))
ELAPSED=$(( $(date +%s) - START_TS ))

sec "RESUMEN FINAL"
log "╔═══════════════════════════════════════════════════════════════════════"
log "║  TIEMPO EJECUCIÓN:     ${ELAPSED} segundos"
log "║  ESPACIO LIBERADO:     ${FREED_MB} MB ($((FREED_MB / 1024)) GB)"
log "║  MODO DE LIMPIEZA:     ${MODE}"
log "║  USUARIOS PROCESADOS:  ${#REAL_USERS[@]}"
log "╚═══════════════════════════════════════════════════════════════════════"

log ""
log "📊 ESTADO DEL DISCO /:"
df -h / | tee -a "$LOG_FILE"
log ""
log "📊 MEMORIA:"
free -h | tee -a "$LOG_FILE"

# Estadísticas adicionales
log ""
log "📈 ESTADÍSTICAS DE LIMPIEZA:"
log "  • Paquetes rc eliminados: $(dpkg -l 2>/dev/null | grep -c '^rc')"
log "  • Espacio en /tmp: $(du -sh /tmp 2>/dev/null | cut -f1)"
log "  • Espacio en /var/tmp: $(du -sh /var/tmp 2>/dev/null | cut -f1)"
log "  • Archivos de log: $(find /var/log -type f -name '*.gz' 2>/dev/null | wc -l) comprimidos"

log ""
log "═══════════════════════════════════════════════════════════════════════"
log "  ✅ LIMPIEZA COMPLETADA - $(date)"
log "═══════════════════════════════════════════════════════════════════════"

exit 0
