---
title: Grundlagen: Akku-Kapazität, Leistung und Laufzeit
slug: grundlagen-akku-kapazitaet-leistung-und-laufzeit
category: Elektrotechnik
categories: Elektrotechnik
tags: akku, laufzeit, berechnen
owner: DP
status: Entwurf
updated: 2026-10-14
summary: 
products: 
attachments: 
revision: 2
change_date: 2026-10-14 14:51
change_action: Geaendert
change_reason: SI Einheit korrigiert
changed_by: dpschibul
related: trivia-optokoppler-transistor
delete_request_by: 
delete_request_at: 
delete_request_reason: 
---

## Grundlagen: Akku-Kapazität, Leistung und Laufzeit

## Grundlage

Unter **Ampere (A)** versteht man die Einheit, in der elektrischer Strom gemessen wird.

Die Kapazität eines Akkus wird in **Amperestunden (A****h)** angegeben. Sie gibt die gespeicherte Elektrizitätsmenge einer Zelle an.

Je mehr Amperestunden ein Akku besitzt, desto länger kann er genutzt werden.

Amperestunden werden auch als **Nennkapazität** bezeichnet.

---

## Grundbegriffe

| Begriff | Einheit | Beschreibung |
| --- | --- | --- |
| Strom | Ampere (A) | Einheit zur Messung des elektrischen Stroms |
| Kapazität | Amperestunden (Ah) | Gibt die gespeicherte Elektrizitätsmenge einer Zelle an |
| Nennkapazität | Amperestunden (Ah) | Bezeichnung für die angegebene Akku-Kapazität |
| Leistung | Watt (W) | Maßeinheit der elektrischen Leistung |
| Energie | Wattstunden (Wh) | Gibt an, welche Energiemenge ein Akku abgeben kann |
| Nennenergie | Wattstunden (Wh) | Bezeichnung für die angegebene Akku-Energie |

---

## Amperestunden (Ah)

Ein Akku mit einer Kapazität von **10 Ah** kann theoretisch:

10 Stunden lang 1 Ampere liefern

Berechnung:

10 Ah = 10 h × 1 A

---

## Wattstunden (Wh)

**Watt (W)** ist die Maßeinheit der elektrischen Leistung.

In **Wattstunden (Wh)** wird bei einem Akku die Energie gemessen, die eine Zelle unter festgelegten Voraussetzungen abgeben kann.

Wenn ein Akku **1 Watt** elektrische Leistung für **1 Stunde** zur Verfügung stellt, liefert der Akku:

1 Wh

Die Wattstunden eines Akkus berechnen sich aus:

Wh = V × Ah

Also:

Wattstunden = Spannung × Kapazität

---

## Beispiel: Berechnung der Wattstunden

Ein Akku hat folgende Angaben:

| Wert | Angabe |
| --- | --- |
| Spannung | 25 V |
| Kapazität | 18 Ah |

Berechnung:

18 Ah × 25 V = 450 Wh

Der Akku besitzt somit eine Nennenergie von:

450 Wh

---

## Wattstunden (Wh) in Amperestunden (Ah) umrechnen

Um **Wattstunden (Wh)** in **Amperestunden (Ah)** umzurechnen, werden die Wattstunden durch die Nennspannung der Batterie dividiert.

Formel:

Ah = Wh / V

Beispiel:

450 Wh / 25 V = 18 Ah

---

## Akkulaufzeit aus Ah und A berechnen

Die Akkulaufzeit kann berechnet werden, indem die Akkukapazität durch den Stromverbrauch geteilt wird.

Formel:

Laufzeit in Stunden = Akkukapazität / Stromverbrauch

Oder:

h = Ah / A

---

## Beispielrechnung: Akkulaufzeit

Ein Akku hat eine Kapazität von:

2 Ah

Der Verbraucher hat eine Stromaufnahme von:

25 µA

### Umrechnung

2 Ah = 2000 mAh

25 µA = 0,025 mA

### Berechnung der Laufzeit

2000 mAh / 0,025 mA = 80.000 h

### Umrechnung in Tage

80.000 h / 24 h = 3333 Tage

### Ergebnis

Ein Akku mit **2 Ah** Kapazität und einem Verbraucher mit **25 µA** Stromaufnahme hätte rechnerisch eine Laufzeit von ca.:

80.000 Stunden

bzw.

3333 Tagen

---

## Formelsammlung

| Berechnung | Formel |
| --- | --- |
| Energie in Wattstunden | `Wh = V × Ah` |
| Kapazität in Amperestunden | `Ah = Wh / V` |
| Laufzeit in Stunden | `h = Ah / A` |
| Laufzeit in Tagen | `Tage = h / 24` |

---

## Quellen

- [Akku-Basics: Watt, Volt und Ampere – Akkuman](https://www.akkuman.de/akku-academy/akku-basics-watt-volt-und-ampere/00511/)
- [Lithium-Ionen-Batterien: Ursache für Selbstentladung von Akkus entdeckt – heise](https://www.heise.de/hintergrund/Lithium-Ionen-Batterien-Ursache-fuer-Selbstentladung-von-Akkus-entdeckt-7517910.html)
- [Battery Life Calculator – DigiKey](https://www.digikey.de/de/resources/conversion-calculators/conversion-calculator-battery-life)

<!-- WIKI_REVISION_LOG_START -->
## Revisionsverlauf
- 2026-06-25 15:23: Revision 1, Angelegt. Grund: Erstellt
- 2026-10-14 14:51: Revision 2, Geaendert durch dpschibul. Grund: SI Einheit korrigiert
<!-- WIKI_REVISION_LOG_END -->
