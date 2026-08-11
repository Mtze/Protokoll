# Meeting Recorder & Protokoll-Pipeline — Architektur

> Lokale, kostenfreie Aufnahme-, Transkriptions- und Protokoll-Pipeline für
> macOS und iOS. Diese Datei ist die maßgebliche Spezifikation für die
> Umsetzung (u. a. durch Claude Code) und dokumentiert die getroffenen
> Entscheidungen samt Begründung.

## Leitidee

Es gibt drei Akteure, die sich alle um dieselben Dateien in einem
iCloud-Container drehen:

- **Apps** — macOS-Menübar-App mit Bibliotheksansicht, iOS-Recorder mit Viewer.
  Sie nehmen auf, zeigen an, durchsuchen und stoßen Verarbeitung an.
- **Container** — die einzige Quelle der Wahrheit: ein Ordner aus offenen Dateien.
- **Pipeline** — ein Verarbeitungsschritt auf dem Mac, der aus Audio ein
  Transkript und daraus ein Protokoll macht.

Grundprinzip: **Die Apps besitzen keine Daten.** Sie sind Ansichten auf den
Container. Jede lokale Datenbank ist nur ein Index und jederzeit aus den
Dateien neu aufbaubar.

---

## Requirements

### Funktionale Anforderungen

- **F1 — Aufnahme (macOS):** Menübar-App, die auf Knopfdruck eine Aufnahme mit
  dem aktuell gewählten Eingabegerät startet und die Audiodatei ablegt.
- **F2 — System-Audio (macOS):** Optionale, getrennte Aufnahme des System-Tons
  (für Video-Calls), zusätzlich zur Mikrofonspur.
- **F3 — Transkription:** Lokale Transkription mit einem hochwertigen Modell;
  Qualität vor Geschwindigkeit.
- **F4 — Protokoll statt Wortprotokoll:** Zusammenfassung mit klar
  dokumentierten Entscheidungen. Diskutierte, aber **nicht** entschiedene Punkte
  werden explizit als solche markiert, damit man sie manuell nachtragen kann.
- **F5 — Agenda-Integration (optional):** Ist eine Agenda vorhanden (Markdown,
  Outline o. ä.), wird das Protokoll an ihr entlang strukturiert — die Agenda
  wird zum ausgefüllten Protokoll.
- **F6 — Bibliothek (macOS):** Vollansicht aller vergangenen Aufnahmen und
  Transkripte für den Überblick.
- **F7 — Projekte/Tags:** Sessions können einem oder mehreren Projekten
  zugeordnet werden (z. B. pro Team, dienstlich/privat), gruppier- und filterbar.
- **F8 — Metadaten:** Datum, Uhrzeit, Dauer, Sprache je Session; auf iOS
  zusätzlich optionaler Geotag.
- **F9 — Benennung:** Sessions manuell benennbar (optional). Ist kein Titel
  gesetzt, vergibt die Pipeline nach der Verarbeitung automatisch einen
  aussagekräftigen Titel — nie eine reine Datums-Wüste.
- **F10 — Volltextsuche:** Auf **beiden** Plattformen, über Transkript **und**
  Protokoll.
- **F11 — iOS-Aufnahme:** Schlanke Aufnahme in denselben iCloud-Container,
  optional mit Titel und Geotag. Keine Verarbeitung auf dem Gerät.
- **F12 — iOS-Ergebnisansicht:** Nach Durchlauf der Mac-Pipeline sind
  Transkript und Protokoll auf iOS sicht-, durchsuch- und weiterverwendbar.
- **F13 — Verarbeitung anstoßen:** Am Mac auf Anfrage; neue (auch per iCloud
  vom iPhone eingegangene) Aufnahmen werden per Notification gemeldet und per
  Klick verarbeitet.

### Nicht-funktionale Anforderungen

- **N1 — Kostenfrei:** Keine API-Keys, keine bezahlten Dienste. Transkription
  lokal; Aufbereitung über die vorhandene Claude-Code-Anmeldung.
- **N2 — Privatsphäre:** Alles bleibt lokal auf den Geräten des Nutzers. Keine
  Uploads an Dritte. Sync ausschließlich über den eigenen iCloud-Container.
- **N3 — Dateien zuerst:** Alles Wichtige liegt als offene Datei vor (Audio +
  Markdown mit Metadaten). Die Dateien sind außerhalb der App voll nutzbar; ein
  einzeln herausgezogener Session-Ordner ergibt für sich Sinn.
- **N4 — Einwilligung/Recht:** Bewusstsein für § 201 StGB (heimliches Aufnehmen
  des gesprochenen Wortes ist strafbar). Sichtbarer Aufnahme-Indikator; optional
  eine Erinnerung vor Aufnahmestart, die Zustimmung einzuholen.
- **N5 — Robuste Aufnahme:** Inkrementelles Schreiben auf die Platte, damit
  Absturz oder leerer Akku nicht die ganze Aufnahme vernichten.
- **N6 — Klare Pipeline-Zustände:** Pro Session nachvollziehbarer Status; jeder
  Schritt einzeln wiederholbar.
- **N7 — iCloud-Verfügbarkeit:** Die Pipeline wartet, bis eine per iCloud
  eingegangene Datei tatsächlich lokal heruntergeladen ist, bevor sie startet.
- **N8 — Mehrsprachigkeit:** Deutsch/Englisch/gemischt. Die Zusammenfassung
  erfolgt in der Sprache des Meetings (oder einer festgelegten Zielsprache).
- **N9 — Lange Transkripte:** Umgang mit sehr langen Transkripten (z. B.
  2-stündige Meetings), ohne den Kontext zu sprengen.
- **N10 — Schonende Versionierung:** Das Rohtranskript bleibt unangetastet.
  Neu generierte Protokolle überschreiben alte nicht verlustbehaftet.

### Nice-to-have (bewusst zurückgestellt)

- **NH1 — Sprechertrennung/Diarisierung:** Nicht ausschlaggebend für die erste
  Version. Getrennte Mic-/System-Spuren liefern später eine grobe Zuordnung
  praktisch geschenkt.
- **NH2 — Ausgelagerte Hintergrundverarbeitung:** Ein späterer Umzug der
  Pipeline in einen Hintergrunddienst bleibt möglich (siehe ADR-1), ist aber
  nicht Teil der ersten Version.
- **NH3 — Pause/Resume der Verarbeitung:** Anhalten laufender Verarbeitung, wenn
  der Nutzer die Ressourcen selbst braucht. An die Chunk-Struktur der Pipeline
  angelehnt (Checkpoint nach Block).

---

## Container-Layout

Jedes Meeting ist eine **Session** mit eigenem Ordner — Audio, Transkript,
Protokoll und Metadaten bleiben zusammen und portabel.

```
Meetings/                              (iCloud ubiquity container)
├── sessions/
│   ├── 2026-08-10T14-30_a1b2c3/       (Ordnername = sortierbar + eindeutig)
│   │   ├── audio/
│   │   │   ├── mic.m4a                (Mikrofonspur)
│   │   │   └── system.m4a            (System-Audio, nur bei Calls)
│   │   ├── transcript.md             (Rohtranskript — wird NIE überschrieben)
│   │   ├── protocol.md               (aktuelles Protokoll)
│   │   ├── protocol.v1.md            (überschriebene Versionen bleiben erhalten)
│   │   ├── agenda.md                 (optional, falls vorhanden)
│   │   └── session.json             (kanonische Metadaten)
│   └── …
└── projects/
    └── projects.json                 (Projekt-/Tag-Definitionen)
```

Der Ordnername beginnt mit dem ISO-Zeitstempel (sortierbar) plus kurzer ID
(kollisionsfrei bei parallelen Aufnahmen auf Mac und iPhone). Der **Anzeigetitel
ist nicht der Ordnername** — der Ordner bleibt stabil, der Titel ist reine
Metadatenschicht, damit Umbenennen keine Referenzen bricht.

---

## Metadatenmodell

Die **kanonischen Metadaten liegen pro Session in `session.json`** und werden
als YAML-Frontmatter in die Markdown-Dateien gespiegelt. Diese Dateien liegen im
Container und synchronisieren sich normal — dadurch *sind* iOS und Mac synchron,
über viele kleine Dateien statt über eine geteilte DB.

`session.json` (Auszug der Felder):

- `id` — stabile Session-ID (entspricht Ordner-Suffix)
- `title` — nullable; von Pipeline gesetzt, wenn nicht manuell vergeben
- `startedAt` / `endedAt` / `duration`
- `device` — `mac` | `ios`
- `geo` — optional (iOS), Koordinaten
- `projects` — Array von Projekt-IDs (referenziert `projects.json`)
- `language` — erkannte/gewählte Sprache
- `consentNote` — optionaler Vermerk zur Einwilligung
- `audioTracks` — vorhandene Spuren (`mic`, ggf. `system`)
- `pipeline` — Statusblock je Schritt (siehe unten)

`projects.json`: Liste aus `id`, `name`, `color`.

---

## Pipeline

Eigenständiges Skript, auch von Hand aufrufbar:

```
process-session <ordner> [--step transcribe|summarize|all] [--force]
```

Ablauf:

1. **Auf iCloud warten (N7).** Sicherstellen, dass die Audiodatei lokal
   heruntergeladen ist (`startDownloadingUbiquitousItem`, dann pollen).
2. **Transkribieren (F3).** `whisper.cpp` mit `large-v3` → `transcript.md` mit
   Zeitstempeln und erkannter Sprache. Danach unveränderlich (N10).
3. **Zusammenfassen (F4/F5/F9).** `claude -p "<prompt>"` im Print-Modus liest
   Transkript (+ optional `agenda.md`) und schreibt `protocol.md`: kein
   Wortprotokoll, Entscheidungen dokumentiert, „diskutiert aber nicht
   entschieden" explizit markiert, Agenda ausgefüllt, Titelvorschlag falls kein
   manueller Titel.
4. **Status schreiben (N6).** Nach jedem Schritt `session.json` aktualisieren.

Zustände: `recorded → transcribing → transcribed → summarizing → done`, plus
`failed` (mit Fehlertext). Jeder Schritt einzeln wiederholbar (`--force`).

**Lange Transkripte (N9)** per Map-Reduce: Transkript in Blöcke teilen (nach
Token-Budget, möglichst an Sprechpausen), jeden Block einzeln zusammenfassen,
finaler Synthese-Durchlauf erzeugt Protokoll, Entscheidungen, offene Punkte und
Titel. Diese Blockgrenzen sind zugleich die Checkpoints für ein späteres
Pause/Resume (NH3).

---

## Audio-Capture

- **Mikrofon (F1):** `AVAudioEngine` auf das gewählte Eingabegerät → `mic.m4a`,
  inkrementell auf die Platte (N5).
- **System-Audio (F2):** `ScreenCaptureKit` (Audio-only `SCStream`) →
  `system.m4a`, nur bei Bedarf. Kommt ohne BlackHole/Kernel-Extension aus.

Getrennte Spuren kosten kaum Mehraufwand und liefern die spätere
Sprechertrennung (NH1) praktisch geschenkt. Das Menübar-Icon signalisiert die
laufende Aufnahme sichtbar (N4).

Die Live-Wellenform (N4) spiegelt beide Quellen: Neben dem Mikrofonpegel
berechnet der System-Audio-Recorder pro `CMSampleBuffer` einen RMS-Pegel
(0...1), und `AppModel` kombiniert Mikrofon- und System-Pegel per Maximum
(`RecordingLevel.combined`), solange System-Audio aufgenommen wird - so leuchtet
die Wellenform auch bei der Gegenseite eines Calls.

---

## iOS-Seite

Bewusst schlank (F11/F12): Aufnahme nach `mic.m4a` in denselben Container,
optional Titel und Geotag (`CLLocation` → `geo`). Keine Verarbeitung auf dem
Gerät. Nach Durchlauf der Mac-Pipeline synchronisiert sich `protocol.md` zurück;
der iOS-Viewer zeigt Transkript und Protokoll, durchsuchbar und
weiterverwendbar. Die Mac-App kann neue iOS-Sessions automatisch übernehmen oder
erst auf Klick (F13).

---

## Übersicht, Tags und Suche

Bibliothek am Mac und Liste auf iOS lesen aus dem lokalen Index (siehe ADR-2):
**FTS5-Volltextsuche über Transkript und Protokoll (F10)** auf beiden
Plattformen, plus Filter nach Projekt/Tag, Datum und Status. Projekte in
`projects.json`, Sessions referenzieren Projekt-IDs. Automatisch gesetzte Titel
(F9) verhindern die reine Datums-Wüste.

---

## Versionierung

`transcript.md` ist unveränderlich, sobald geschrieben. Beim Neu-Generieren wird
das aktuelle `protocol.md` nach `protocol.vN.md` rotiert und ein neues
geschrieben — nichts geht verloren (N10).

---

## Tech-Stack

- **Apps:** Swift/SwiftUI (macOS + iOS), gemeinsames Swift-Package für das
  Datenmodell (Container-Zugriff, `session.json` lesen/schreiben).
- **Index:** SQLite mit FTS5 (z. B. via GRDB), lokal, wegwerfbar.
- **Pipeline:** eigenständiges Skript, von der Menübar-App als Subprozess
  gestartet (ADR-1).
- **Transkription:** `whisper.cpp`, `large-v3` (alternativ `large-v3-turbo`,
  falls Geschwindigkeit wichtiger wird).
- **Aufbereitung:** Claude Code CLI (`claude -p`, Print-Modus), über die
  bestehende Anmeldung — kein API-Key (N1).

Harte Abhängigkeit: `claude` ist auf dem Mac installiert und eingeloggt;
`whisper.cpp` mit heruntergeladenem Modell verfügbar.

---

## Architekturentscheidungen (ADRs)

### ADR-1 — Verarbeitung als Subprozess, nicht als Hintergrund-Daemon

**Status:** akzeptiert.

**Entscheidung:** Die Menübar-App startet `process-session` als Kindprozess.
Kein launchd-LaunchAgent, kein IPC.

**Kontext & Begründung:**

- *Für den Subprozess:* deutlich einfacher — kein Daemon, kein IPC-Overhead,
  weniger bewegliche Teile für ein persönliches Tool. Er fügt sich in das
  Framing „Verarbeitung ist eine bewusste Nutzerentscheidung" ein: Neue
  Aufnahmen (v. a. per iCloud vom iPhone) melden sich per lokaler Notification
  mit Action-Button („Neue Aufnahme, jetzt verarbeiten?"); ein Klick startet den
  Lauf. So wird nicht unerwartet CPU abgezogen. Laufen mehrere Aufträge, werden
  sie seriell in eine Queue gehängt (paralleles `large-v3` thrasht nur).
- *Gegen den Subprozess (bekannte Konsequenz):* Die Verarbeitung lebt nur,
  solange die App läuft. Beenden mitten in der Transkription bricht den Lauf ab.
  Akzeptabel, weil Schritte wiederholbar sind (N6) und die Map-Reduce-Blöcke als
  Checkpoints dienen können (NH3).

**Verworfene Alternative:** launchd-LaunchAgent (überlebt App-Beendigung, läuft
im Hintergrund). Zurückgestellt als NH2 — kann später nachgezogen werden, ohne
die Datei-/Container-Struktur zu ändern.

### ADR-2 — Lokaler, wegwerfbarer Index statt geteilter DB im Container

**Status:** akzeptiert.

**Entscheidung:** Kanonische Metadaten liegen in den Dateien (`session.json` +
Frontmatter). Sync läuft über diese Dateien im iCloud-Container. Suche/Übersicht
speist sich aus einem **rein lokalen SQLite-Index pro Gerät** (im
App-Support-Ordner, außerhalb des Containers), der aus den Dateien aufgebaut und
bei Bedarf neu erzeugt wird.

**Kontext & Begründung:**

Die halbe Entscheidung erzwingt N3 („Dateien zuerst"): Sobald die Identität
einer Session nur in einer DB stünde, wäre ein herausgezogener Ordner wertlos.
Also *muss* die Wahrheit in den Dateien liegen. Bleibt die Frage nach der Sync-
und Suchschicht obendrauf. Drei Kandidaten:

- **Geteilte SQLite im Container.**
  *Dafür:* ein einziger Speicher, keine Rebuild-Logik.
  *Dagegen:* iCloud synchronisiert ganze Dateien und kann zwei schreibende
  Geräte nicht zeilenweise mergen → Konfliktkopien; SQLites `-wal`/`-shm`-
  Sidecars syncen nicht atomar mit. Dokumentiertes Anti-Pattern. Zudem
  redundant, da die Dateien die Wahrheit ohnehin tragen.
- **Lokaler wegwerfbarer Index pro Gerät (gewählt).**
  *Dafür:* kein geräteübergreifender DB-Konflikt, da der Index privat ist und
  nie synchronisiert. Aus den Dateien wiederaufbaubar — Korruption wird zum
  Nicht-Ereignis. FTS5 liefert schnelle Volltextsuche.
  *Dagegen:* braucht einen Indexer, der den Container beobachtet; gleichzeitige
  Metadaten-Edits derselben Session auf zwei Geräten können einen iCloud-Konflikt
  auf *dieser einen* `session.json` erzeugen — isoliert, selten, verlustfrei
  (iCloud behält beide Versionen).
- **CloudKit als Sync-/Indexschicht (Dateien bleiben kanonisch).**
  *Dafür:* echtes Record-Level-Sync mit Konfliktauflösung, skaliert.
  *Dagegen:* deutlich mehr Komplexität (Schema, Subscriptions, Merge) und zwei
  abzugleichende Speicher. Für ein persönliches Tool überdimensioniert und
  redundant, da die Dateien die Wahrheit tragen.

**Begründung der Wahl:** Weil die Dateien ohnehin die Wahrheit tragen, ist der
einzige Job der Sync-Schicht, eine schnelle, lokale, wegwerfbare Ansicht zu
sein. Das Billigste, was das erfüllt, ist ein pro Gerät neu baubarer Index. Er
eliminiert die gesamte Fehlerklasse „synchronisierte DB korrumpiert", indem er
nie eine DB synchronisiert. CloudKit wäre die Antwort, wenn die Dateien die
Wahrheit *nicht* trügen; die geteilte DB im Container bekäme das Schlechteste
beider Welten (fragiles Sync *und* redundante Wahrheit).

**Vorbehalt & Mitigation:** Gleichzeitige Metadaten-Edits derselben Session auf
zwei Geräten → iCloud-Konflikt auf `session.json`. Solche Edits sind selten und
meist einseitig; im Konfliktfall gewinnt der neuere Stand (mtime), die App zeigt
es an, dank iCloud-Versionshaltung geht nichts verloren. Für ein persönliches
Tool akzeptabel.

### ADR-3 — Aufnahme in streambares CAF, Konvertierung zu m4a beim Stopp

**Status:** akzeptiert (Umsetzung M1).

**Entscheidung:** Die Mikrofonaufnahme wird inkrementell in eine streambare
CAF-PCM-Datei (`audio/mic.caf`) geschrieben und beim Stopp nach `audio/mic.m4a`
(AAC) konvertiert (via `AVAssetExportSession`, ohne ffmpeg-Shell-out). Beim
App-Start werden verwaiste `mic.caf` ohne zugehörige `mic.m4a` erkannt und
nachträglich konvertiert.

**Kontext & Begründung:**

- *Für CAF-dann-Konvertieren:* Ein `.m4a`/MPEG-4-Container wird erst beim
  ordnungsgemäßen Schließen finalisiert (moov-Atom am Ende). Stürzt die App ab
  oder ist der Akku leer, ist eine direkt geschriebene `.m4a` unbrauchbar. CAF
  mit LPCM wird Frame für Frame auf die Platte geschrieben und übersteht einen
  Absturz - genau die von N5 geforderte Robustheit. Die verlustfreie
  Wiederherstellung beim nächsten Start macht den Absturz zum Nicht-Ereignis.
- *Gegen CAF:* CAF-PCM ist groß (unkomprimiert). Akzeptabel, weil die Datei nur
  bis zum Stopp existiert und sofort in kompaktes AAC überführt wird; der Nutzen
  (keine verlorene Aufnahme) überwiegt die kurzlebige Plattenlast deutlich.

**Verworfene Alternative:** Direkt nach `.m4a` schreiben (kleinere Dateien, kein
Konvertierungsschritt) - verworfen, weil ein Absturz die gesamte Aufnahme
vernichtet und N5 damit verletzt wäre.

### ADR-4 — Ressourcenbewusster Scheduler mit Claim/Lease statt globaler Queue

**Status:** akzeptiert (Umsetzung M1, voll ausgereizt ab M2).

**Entscheidung:** Verarbeitung läuft nicht über eine einzige globale serielle
Queue, sondern über einen ressourcenbewussten Scheduler: **Transkription = 1
global**, **eine Zusammenfassung darf eine laufende Transkription überlappen**.
Der Scheduler-Kern liegt hinter einer Schnittstelle, entkoppelt von der App-UI,
sodass später ein launchd-Daemon oder ein *zweiter Mac* denselben Kern hosten
kann (NH2). Jeder laufende Schritt trägt einen **Claim/Lease** in `session.json`
(`deviceId`, `step`, `startedAt`, `heartbeat`); ein Lease gilt als abgelaufen,
wenn der Heartbeat älter als 120 s ist, und darf dann übernommen werden.

**Kontext & Begründung:**

- *Für zwei Slots statt seriell:* `large-v3`-Transkription sättigt die
  Neural-Engine/GPU; zwei parallele Transkriptionen thrashen nur (daher = 1).
  Die Zusammenfassung ist dagegen `claude`-gebunden (Netz/CLI) und konkurriert
  nicht um dieselbe Ressource - sie darf eine Transkription überlappen und
  verkürzt so die Gesamtlaufzeit spürbar.
- *Für Claim/Lease ab Tag 1:* Der Container ist geräteübergreifend (iCloud).
  Ohne Lease könnten Mac und ein späterer zweiter Host dieselbe Session doppelt
  verarbeiten. Der Lease mit Heartbeat und Ablauf deckt zugleich den Absturzfall
  ab (ein abgestürzter Host blockiert die Session nicht dauerhaft) und ist die
  Grundlage für den entkoppelten Daemon aus NH2.
- *Konsequenz (bewusst):* Der Scheduler lebt nur, solange die App läuft (ADR-1).
  Ein beim Beenden abgebrochener Job hinterlässt einen Checkpoint und ist
  wiederholbar (N6); Confirm-on-Quit warnt vor laufender Arbeit.

**Verworfene Alternative:** Globale serielle Queue (ein Job nach dem anderen) -
einfacher, aber sie verschenkt die kostenlose Überlappung Zusammenfassung/
Transkription und trägt keine Mehrhost-Sicherheit. Der Lease-Zustand ließe sich
nicht nachrüsten, ohne das Statusmodell zu ändern.

### ADR-5 — Suchindex über das System-SQLite (FTS5) statt GRDB

**Status:** akzeptiert (Umsetzung M3). Ersetzt die Werkzeugwahl aus
Plan-Entscheidung #13 (GRDB), nicht die Architektur (ADR-2 bleibt unverändert).

**Entscheidung:** Der lokale, wegwerfbare FTS5-Index (ADR-2) nutzt direkt die
in macOS/iOS enthaltene `libsqlite3` (`import SQLite3`) über einen dünnen
eigenen Wrapper, statt die externe SPM-Abhängigkeit GRDB einzuziehen.

**Kontext & Begründung:**

- *Für System-SQLite:* Der Index braucht genau drei Dinge - eine Metadaten-
  Tabelle, eine FTS5-Volltexttabelle und parametrisierte Queries. Das
  System-SQLite auf Apple-Plattformen bringt FTS5 bereits mit; der nötige
  Wrapper ist wenige Dutzend Zeilen. Das hält die Zusage aus Entscheidung #13
  ein, bis M3 überhaupt keine Abhängigkeit einzuziehen, und darüber hinaus:
  **null externe Abhängigkeiten** für das gesamte Projekt. Kein Netzwerk-Fetch
  beim Build, kein Versions-Pinning, keine fremde Concurrency-Semantik im Weg
  der Swift-6-Strict-Concurrency. „Einfachste korrekte Lösung" (harte
  Projektvorgabe) spricht klar dafür.
- *Gegen System-SQLite (bewusst):* GRDB böte typsichere Query-Builder,
  Migrations-Helfer und Record-Mapping. Für einen wegwerfbaren Index mit einer
  Tabelle und einer FTS5-View ist das Overhead ohne Gegenwert; der Index wird
  bei Schemaänderung ohnehin neu gebaut (ADR-2), also braucht es keine
  Migrationsmaschinerie.

**Verworfene Alternative:** GRDB als SPM-Abhängigkeit (Plan #13). Zurückgestellt,
weil sie für den minimalen Indexbedarf überdimensioniert ist und die
Null-Abhängigkeits-Eigenschaft des Projekts aufgäbe. Ein späterer Wechsel bliebe
lokal möglich, da der Index hinter der `SearchIndex`-Actor-Schnittstelle liegt
und jederzeit neu baubar ist.

### ADR-6 - watchOS synchronisiert über WatchConnectivity zum iPhone, nicht direkt

**Status:** akzeptiert (offene Entscheidung vor M6, wie im Plan gefordert).

**Entscheidung:** Die Apple-Watch-App nimmt lokal auf und überträgt die fertige
Audiodatei per **WatchConnectivity** (`WCSession.transferFile`) an die
iPhone-App; diese legt daraus eine neue Session im iCloud-Container an (Gerät
`watch`). Die Watch schreibt **nicht** direkt in den Ubiquity-Container.

**Kontext & Begründung:**

- *Warum nicht direkt:* watchOS hat keinen Zugriff auf den iCloud-Ubiquity-
  Container des Nutzers wie macOS/iOS. Ein direkter Containerzugriff von der
  Uhr ist schlicht nicht verfügbar - die Uhr braucht einen Vermittler.
- *Für WatchConnectivity (gewählt):* Es ist der native, kostenfreie Pfad
  Uhr-zu-iPhone, überträgt Dateien auch im Hintergrund (`transferFile` läuft
  opportunistisch weiter) und braucht **kein zusätzliches Cloud-Schema**. Es
  wiederverwendet den bereits gebauten iOS-zu-Container-Pfad (M4): die
  iPhone-App muss die empfangene Datei nur in `createSession(device: .watch)`
  ablegen. Das hält N1/N2 (kostenlos, lokal) ein.
- *Gegen CloudKit:* Ein CloudKit-Pfad Uhr-zu-Cloud-zu-Mac würde einen zweiten
  Speicher und ein Record-Schema einführen (dieselbe Redundanz, die ADR-2 für
  die Suchschicht ablehnt) und wäre für ein persönliches Tool überdimensioniert.
- *Konsequenz (bewusst):* Die Übertragung landet erst im Container, wenn die
  iPhone-App die Datei empfangen hat (Uhr in Reichweite bzw. später beim
  nächsten Sync). Für eine Aufnahme, die ohnehin erst am Mac verarbeitet wird,
  ist diese Latenz unkritisch.

**Verworfene Alternative:** CloudKit als Uhr-Sync-Schicht. Zurückgestellt wegen
Mehrkomplexität und Redundanz zum dateibasierten Wahrheitsmodell (N3).

### ADR-7 — Ein gemischter Audio-Track für die Transkription

**Status:** akzeptiert.

**Entscheidung:** Wird System-Audio (F2) aufgenommen, mischt die App beim
Stoppen die Mikrofon- und die System-Spur zu einer einzigen `mic.m4a`
(`AudioMixer`, AVFoundation-Komposition). Die separate `system.m4a` wird nach
dem Mischen entfernt; `audioTracks` bleibt `[.mic]`.

**Kontext & Begründung:** Die Pipeline transkribiert `mic.m4a`. Bei getrennten
Spuren landete nur das Mikrofon im Transkript - der Ton der Gegenseite (z. B.
Discord) fehlte. Das Zusammenmischen liefert genau einen Track, der die ganze
Unterhaltung enthält, ohne die Pipeline zu ändern.

**Konsequenz:** Die in NH1 angedachte „geschenkte" grobe Sprechertrennung aus
getrennten Spuren entfällt vorerst. Wird Diarisierung später verfolgt, können
die Rohspuren zusätzlich unter `audio/` erhalten und ein Werkzeug wie WhisperX
eingesetzt werden. Für die aktuelle Anforderung („ein funktionierendes
Transkript der ganzen Besprechung") überwiegt der einzelne gemischte Track.

### ADR-8 — Verteilung über ein Homebrew-Cask + GitHub-Releases

**Status:** akzeptiert.

**Entscheidung:** Die Mac-App wird als **Homebrew-Cask** (`Casks/protokoll.rb`)
verteilt, das auf ein gezipptes `Protokoll.app` in den **GitHub-Releases** zeigt.
Ein tag-getriggerter Workflow (`.github/workflows/release.yml`) baut die App,
signiert und notarisiert sie **optional** (nur wenn die Signing-Secrets gesetzt
sind), zippt sie, veröffentlicht das Release und aktualisiert `version` + `sha256`
im Cask automatisch. Das Cask liegt in diesem App-Repo; die Installation nutzt
daher die Zwei-Argument-Form
`brew tap mtze/protokoll https://github.com/Mtze/Protokoll`.

**Kontext & Begründung:**
- Für eine GUI-`.app` ist ein **Cask** (nicht eine Formula) der richtige
  Homebrew-Mechanismus.
- Ein eigenes `homebrew-protokoll`-Repo wäre die Standardkonvention, ist aber für
  ein persönliches Tool Overhead. Das Cask im App-Repo zu halten spart ein zweites
  Repo; bewusster Nachteil: jedes `brew update` holt das ganze App-Repo statt eines
  schlanken Tap-Repos.
- Signieren/Notarisieren erfordert ein Developer-ID-Zertifikat und einen Apple-
  Developer-Account (ADR-3: die App ist nicht sandboxed, weil sie fremde CLIs
  ausführt). Solange diese fehlen, läuft die Auslieferung **unsigniert**; der
  Workflow-Schritt ist per Secret-Gate vorbereitet und wird ohne Code-Änderung
  aktiv, sobald die Secrets vorliegen.

**Konsequenz (bewusst):** Bis zur Notarisierung blockiert Gatekeeper den ersten
Start (unter macOS 15 ohne den alten Rechtsklick-Öffnen-Umweg); Nutzer bestätigen
über *Systemeinstellungen > Datenschutz & Sicherheit* oder installieren mit
`--no-quarantine`. Der Cask-Bump-Schritt pusht auf `main` - bei Branch-Schutz muss
der Bump stattdessen per PR erfolgen.
