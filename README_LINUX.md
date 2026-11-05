# Firmen-Wiki – Linux-Hosting (Orange Pi PC)

Diese Kopie ist die Linux-Variante. Das Original (`WIKI/`) wurde nicht veraendert.
Windows-Dateien (`start-windows.bat`, `tools/*.ps1`-Server, EXE-Launcher) bleiben
als Referenz erhalten; aktiv ist auf Linux nur `server/wiki_server.py`.

## Start (manuell)

```bash
chmod +x start-linux.sh
PORT=8765 BIND=0.0.0.0 ./start-linux.sh
# oder
python3 server/wiki_server.py --port 8765 --bind 0.0.0.0 --root /opt/wiki
```

Danach: `http://<PI-IP>:8765/` – beim ersten Aufruf Admin-Konto anlegen
(es gibt kein Standardpasswort, PBKDF2-SHA256, 120k Iterationen).

## Install als Dienst (Orange Pi, Armbian)

```bash
sudo mkdir -p /opt/wiki
sudo rsync -a --exclude versions/ --exclude .git/ ./ /opt/wiki/
sudo cp wiki-hosting.service /etc/systemd/system/wiki-hosting.service
sudo systemctl daemon-reload
sudo systemctl enable --now wiki-hosting
systemctl status wiki-hosting
```

## Hinweise fuer dieses Board

- Getestet fuer `armv7l`, Python3 aus den Systemquellen (keine Pakete noetig,
  nur Standardbibliothek).
- Daten bleiben filebasiert unter `content/`, `config/`, `data/wiki-data.js`
  (wird beim Start/neuen Build frisch geschrieben).
- Snapshots: nach Mutationen wird per `git commit` versioniert (wenn `/opt/wiki`
  ein Git-Repo ist), Fehler landen in `versions/snapshot-errors.log`.
- Unterschied zu Windows: kein Tray, kein ScheduledTask, kein `powershell.exe`.
  Autostart laeuft ueber systemd oben.
- RAM (~1GB): Desktop (lightdm/Xorg) auf dem Pi frisst ~150MB – fuer reinen
  Serverbetrieb ggf. deaktivieren.
