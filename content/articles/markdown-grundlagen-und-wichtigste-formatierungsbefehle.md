---
title: Markdown – Grundlagen und wichtigste Formatierungsbefehle
slug: markdown-grundlagen-und-wichtigste-formatierungsbefehle
category: Wiki Anleitung
categories: Wiki Anleitung
tags: 
owner: DPschibul
status: Entwurf
updated: 2026-10-16
summary: 
products: 
attachments: 
revision: 1
change_date: 2026-10-16 13:11
change_action: Angelegt
change_reason: Erstellt
changed_by: dpschibul
related: neuen-artikel-anlegen
delete_request_by: 
delete_request_at: 
delete_request_reason: 
---

Markdown ist eine einfache Auszeichnungssprache, mit der Texte mithilfe bestimmter Sonderzeichen formatiert werden können. Die Formatierung erfolgt direkt bei der Texteingabe und wird vom Editor entsprechend dargestellt.

#### Wichtigste Markdown-Befehle

| Formatierung | Markdown-Eingabe | Ergebnis |
| --- | --- | --- |
| Überschrift 1 | `# Überschrift` | Große Überschrift |
| Überschrift 2 | `## Überschrift` | Mittlere Überschrift |
| Überschrift 3 | `### Überschrift` | Kleine Überschrift |
| Fett | `**Text**` | Text |
| Kursiv | `*Text*` | Text |
| Fett und kursiv | `***Text***` | Text |
| Durchgestrichen | `~~Text~~` | Text |
| Aufzählung | `- Eintrag` | Aufzählungspunkt |
| Nummerierte Liste | `1. Eintrag` | Nummerierter Eintrag |
| Checkbox (offen) | `- [ ] Aufgabe` | Leere Checkbox |
| Checkbox (erledigt) | `- [x] Aufgabe` | Markierte Checkbox |
| Link | `[ABUS](https://www.abus.com)` | Klickbarer Link |
| Bild | `![Beschreibung](bild.png){width=420}` | Eingebundenes Bild |
| Zitat | `> Text` | Eingerücktes Zitat |
| Inline-Code | `` `Code` `` | `Code` |
| Trennlinie | `---` | Horizontale Linie |
| Zeilenumbruch | Zwei Leerzeichen am Zeilenende | Neue Zeile |

#### Tabellen erstellen

Tabellen werden mit dem senkrechten Strich `|` und Bindestrichen `-` erstellt.

**Markdown-Eingabe**

.```

|---|---|

| Admin | Verwaltung |

| Benutzer | Bedienung |

.```

**Ergebnis:**

| Name | Funktion |
| --- | --- |
| Admin | Verwaltung |
| Benutzer | Bedienung |

#### Codeblöcke erstellen

Für mehrzeilige Codeblöcke werden drei Backticks ``` vor und nach dem Code verwendet.

.```

const int ldrPin = A0;

const int ledPin = A1;

int lichtwert = 0;

// Schwellwert zwischen hell und dunkel

int schwelle = 500;

void setup() {

pinMode(ledPin, OUTPUT);

Serial.begin(9600);

}

.```

### Zusätzliche Kommentare

- Zwischen Überschriften, Listen und Absätzen empfiehlt sich jeweils eine Leerzeile.
- Für Unterpunkte in Listen werden Leerzeichen zur Einrückung verwendet.
- Sonderzeichen wie `*`, `#` oder `_` können mit einem vorangestellten Backslash `\` als normaler Text dargestellt werden.
- Nicht jeder Markdown-Editor unterstützt sämtliche Funktionen, insbesondere Tabellen, Checkboxen und erweiterte Formatierungen.
- Eine Vorschaufunktion ermöglicht die Kontrolle der Formatierung vor dem Speichern.

Tipp: Für die Erstellung von KB-Artikeln sind insbesondere Überschriften (`#`), Fettschrift (`**`), Aufzählungen (`-`) und Tabellen (`|`) hilfreich, um Informationen übersichtlich darzustellen.

<!-- WIKI_REVISION_LOG_START -->
## Revisionsverlauf
- 2026-10-16 13:11: Revision 1, Angelegt durch dpschibul. Grund: Erstellt
<!-- WIKI_REVISION_LOG_END -->
