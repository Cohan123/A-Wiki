---
title: Trivia Optokoppler / Transistor
slug: trivia-optokoppler-transistor
category: Elektrotechnik
categories: Elektrotechnik
tags: optokoppler, halbleiter, transistor
owner: DP
status: Entwurf
updated: 2026-06-25
summary: 
products: 
attachments: 
revision: 1
change_date: 2026-06-25 15:30
change_action: Angelegt
change_reason: Erstellt
related: grundlagen-akku-kapazitaet-leistung-und-laufzeit
---

## Optokoppler und Transistoren

## Optokoppler

![Optokoppler.png](content/uploads/bilder/Optokoppler.png){width=420}


Ein **Optokoppler** wird auch als **optoelektronisches Koppelelement** bezeichnet.

Er ermöglicht die Übertragung von Signalen zwischen zwei **galvanisch getrennten Stromkreisen**.

### Aufbau

Im Optokoppler befinden sich:

| Bauteil | Funktion | Beispiel |
|---|---|---|
| Leuchtdiode | Sender | Infrarot-GaAs-Diode |
| Fototransistor | Empfänger | Fototransistor |

Die Leuchtdiode kann z. B. als **Infrarot-GaAs-Diode** ausgeführt sein. Diese besitzt einen hohen Wirkungsgrad und ist alterungsbeständig.

Sender und Empfänger befinden sich einander optisch gegenüber. Sie sind nach außen lichtdicht abgeschirmt.

### Einsatzbereiche

Optokoppler werden unter anderem eingesetzt in:

- Mess- und Regeltechnik
- Nachrichtentechnik
- Datenverarbeitung

Dadurch eignen sie sich optimal als Eingang der:

- **AE255/F**
- **WLX**

---

## Galvanische Trennung

Unter **galvanischer Trennung** versteht man das Vermeiden einer elektrischen Leitung zwischen zwei Stromkreisen, zwischen denen Leistung oder Signale ausgetauscht werden sollen.

Weitere Bezeichnungen:

- Galvanische Entkopplung
- Potentialtrennung

---

## Transistor

Transistoren sind verstärkende, aktive Halbleiterbauelemente.

Man unterscheidet grundsätzlich zwischen:

- Bipolaren Transistoren
- Unipolaren Transistoren
![Transistor.png](content/uploads/bilder/Transistor.png){width=420}

---

## Bipolare Transistoren

Bipolare Transistoren werden meist aus Silizium hergestellt.

Sie bestehen aus drei übereinanderliegenden Halbleiterschichten, bei denen sich **P- und N-Leiter** abwechseln.

Je nach Zonenfolge entsteht ein:

| Typ | Aufbau |
|---|---|
| PNP-Transistor | P-N-P |
| NPN-Transistor | N-P-N |

Als Einzeltransistoren werden überwiegend **NPN-Transistoren** eingesetzt.

---

## Anschlüsse eines bipolaren Transistors

Die drei Halbleiterzonen sind kontaktiert und führen als Anschlüsse nach außen.

| Anschluss | Beschreibung |
|---|---|
| Basis | Mittlere Zone |
| Emitter | Äußere Zone, sendet Ladungsträger aus |
| Kollektor | Äußere Zone, sammelt Ladungsträger ein |

Der **Emitter** sendet Ladungsträger aus, die der **Kollektor** wieder einsammelt.

Am Übergang vom N-Leiter zum P-Leiter bilden sich Sperrschichten aus. Beim bipolaren Transistor entstehen somit zwei Sperrschichten.

---

## Betriebsrichtung

Im Transistorbetrieb gilt:

| Strecke | Polung |
|---|---|
| Basis-Emitter-Strecke | Durchlassrichtung |
| Basis-Kollektor-Strecke | Sperrrichtung |

Der Emitter-Pfeil im Transistor-Schaltzeichen gibt die technische Stromrichtung an.

---

## Transistor als Schalter

Ein Transistor kann als elektronischer Schalter eingesetzt werden, um kleine Lasten schnell und kontaktlos zu schalten.

Beim Schalten des Transistors, z. B. als Ausgang der **AE255/F**, sind hauptsächlich zwei Schaltzustände wichtig:

| Schaltzustand | Bedeutung |
|---|---|
| Sperrend | Kein interner Scharfschaltbefehl |
| Leitend | Interner Scharfschaltbefehl, +12 V werden ausgegeben |

---

## Funktionsweise

Als Schalter wirkt die **Kollektor-Emitter-Strecke C-E**.

Diese kann zwei Zustände annehmen:

| Zustand | Beschreibung |
|---|---|
| Sehr hochohmig | Transistor ist gesperrt |
| Niederohmig | Transistor ist leitend |

Der Steueranschluss ist die **Basis-Emitter-Strecke B-E**.

Diese ist intern an die Logik der AE angeschlossen.

---

## Beispiel: Ausgang AE255/F

### Gesperrter Transistor

Bei gesperrtem Transistor wird an Ausgang **4/21** kein 12-V-Impuls ausgegeben.


IB = 0 A
UCE = 0 V


### Leitender Transistor

Bei leitendem Transistor wird an Ausgang **4/21** ein kurzer Impuls von **12 V** ausgegeben.


Ausgang 4/21 = +12 V Impuls

<!-- WIKI_REVISION_LOG_START -->
## Revisionsverlauf
- 2026-06-25 15:30: Revision 1, Angelegt. Grund: Erstellt
<!-- WIKI_REVISION_LOG_END -->
