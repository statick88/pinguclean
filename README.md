# pinguclean

Automated cleanup and maintenance script for Kali Linux. Removes caches, logs, temp files, Docker artifacts, old kernels, and pentesting tool residuals — safely and idempotently.

## Quick path

```bash
# Install
sudo install -o root -g root -m 750 pinguclean.sh /usr/local/sbin/pinguclean.sh

# Add alias to .zshrc
echo 'pingu() { sudo /usr/local/sbin/pinguclean.sh "$@"; }' >> ~/.zshrc && source ~/.zshrc

# Run
sudo pingu              # light mode (daily)
sudo pingu --deep       # deep mode (weekly)
sudo pingu --aggressive # aggressive mode (monthly)
sudo pingu --dry-run    # preview without changes
```

## What it cleans

| Category | Light | Deep | Aggressive |
|----------|-------|------|------------|
| APT cache & orphan packages | ✓ | ✓ | ✓ |
| System logs & journald | ✓ | ✓ | ✓ |
| Temp files (`/tmp`, `/var/tmp`) | ✓ | ✓ | ✓ |
| User caches (browser, IDE, thumbnails) | ✓ | ✓ | ✓ |
| Package managers (pip, npm, cargo, gem, yarn, composer, go) | ✓ | ✓ | ✓ |
| Docker prune | — | ✓ | ✓ |
| Old kernels & headers | — | ✓ | ✓ |
| Snap/Flatpak cleanup | — | ✓ | ✓ |
| TRIM (SSD optimization) | — | ✓ | ✓ |
| RAM cache release | ✓ | ✓ | ✓ |
| Aggressive log truncation | — | — | ✓ |
| Timeshift snapshot removal | — | — | ✓ |

## Safety contract

- **NO** package removal (except orphan autoremove)
- **NO** user file modification outside known caches
- **NO** system configuration changes
- **NO** `.bashrc` or shell config touching
- Idempotent — safe to run multiple times
- Lock file prevents concurrent execution

## Architecture

```
pinguclean.sh
├── Configuration (mode detection, variable overrides)
├── Helpers (logging, runq, root check, user detection)
├── Modules
│   ├── cleanup_apt()              # APT packages & caches
│   ├── cleanup_logs()             # System logs & journald
│   ├── cleanup_tmp()              # Temp files (X11-safe)
│   ├── cleanup_user_caches()      # Per-user caches
│   ├── cleanup_package_managers() # pip, npm, cargo, etc.
│   ├── cleanup_docker()           # Docker, kernels, snap, flatpak
│   ├── cleanup_aggressive_extras()# Aggressive-only cleanups
│   ├── cleanup_ram()              # RAM cache release
│   └── cleanup_optimizations()    # updatedb, DNS, dpkg
└── main()                         # Orchestration & summary
```

## Testing

```bash
# Run the test suite (requires root)
sudo bash tests/test_pinguclean.sh

# Static analysis
shellcheck -x pinguclean.sh
```

## Logs

All operations are logged to `/var/log/kali-cleanup/cleanup-YYYYMMDD_HHMMSS.log`. Logs older than 14 days are auto-rotated.

## License

MIT
