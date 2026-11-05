# A-Wiki

Öffentliche Ausgabe der Firmen-Wissensdatenbank auf Basis der aktuellen Wiki-Version vom 05.11.2026.

## Inhalt dieser Veröffentlichung

Enthalten sind ausschließlich Artikel der Bereiche:

- **Wiki** – Kategorie `Wiki Anleitung`
- **Technik** – Kategorien `Elektrotechnik` und `IT&Systeme`

Nicht enthalten sind:

- Artikel anderer Kategorien (z. B. Produkt- und Zutrittskategorien)
- Archivartikel
- Produkt- und Benutzerdaten
- Laufzeit-, Backup- und Konfigurationsdaten

Verknüpfungen zu nicht enthaltenen Artikeln wurden entfernt.

## Start unter Windows

```powershell
.\start-windows.bat
```

Alternativ:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\editor-server.ps1
```

Danach ist das Wiki unter `http://127.0.0.1:8765/` erreichbar. Beim ersten Aufruf wird ein Administratorkonto angelegt; es gibt kein Standardpasswort. Benutzerkonten werden nur lokal gespeichert und nicht in dieses Repository aufgenommen.

## Start unter Linux

```bash
./start-linux.sh
```

Details: [`README_LINUX.md`](README_LINUX.md)

## Funktionen

- Artikel, Kategorien und Produktgruppen
- Markdown- und Rich-Text-Editor
- Rollen und Rechte
- Änderungsvorschläge und Löschanträge
- Archiv und Wiederherstellung
- Suche und Filter
- **Bidirektionale Verknüpfung verwandter Artikel**
- Uploads für Bilder und Dokumente
- Backup- und Snapshot-Funktionen

## Verwandte Artikel

Verknüpfungen zwischen Artikeln werden beim Speichern automatisch auf beiden Seiten gepflegt. Wird ein Link entfernt, wird auch die Gegenverknüpfung entfernt. Doppelte Einträge werden verhindert; bestehende und parallel hinzugekommene Links bleiben erhalten.

## Lizenz und Nutzung

Dieses Repository enthält einen öffentlichen Auszug der Wiki-Anwendung und ausgewählte Inhalte. Vertrauliche Produkt-, Kunden- und Benutzerdaten sind nicht Bestandteil der Veröffentlichung.
