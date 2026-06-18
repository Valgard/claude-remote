# claude-remote — Design

**Datum:** 2026-06-15
**Status:** Design abgenommen, bereit für Implementierungsplan

## Problem

Claude-Code-Sessions sollen von einem anderen Gerät (iPad, Blink) aus erreichbar
sein, „als wären sie lokal". Konkrete Schmerzpunkte des Nutzers:

1. **Kein manuelles Session-Setup.** `tmux new -s …` von Hand vor jedem
   Claude-Aufruf nervt — es soll automatisch passieren.
2. **Session-Auswahl beim Verbinden.** Beim Connect vom iPad soll eine Liste der
   laufenden Sessions erscheinen, aus der ausgewählt wird.

Mehrere Claude-Sessions **im selben Verzeichnis** sind der Normalfall, nicht die
Ausnahme (jede interaktive Claude-TUI belegt ein Terminal, also startet jede aus
einer eigenen Shell).

## Nicht-Ziele (YAGNI)

- Kein eigener PTY-Server / kein eigenes Wire-Protokoll / kein eigener Client
  (würde tmux + mosh neu erfinden).
- Kein VPN-Aufbau: Beide Geräte sind im **selben lokalen Netz** (FritzBox-WLAN
  zuhause: Mac im Arbeitszimmer, iPad im Wohnzimmer; unterwegs beide am
  iPhone-Hotspot). Erreichbarkeit ist damit ein gelöstes Problem.
- Kein Registry-Daemon: Discovery + Metadaten liefert `abtop` (read-only,
  pull-basiert → kein Stale-Problem).

## Architektur-Überblick

Es gibt **keinen langlaufenden Eigen-Prozess**. Drei der vier „Server"-Aufgaben
sind an bewährte, fremdgewartete Bausteine delegiert:

| Aufgabe                          | Baustein            |
|----------------------------------|---------------------|
| Persistenz + Lifecycle + Attach  | `tmux`              |
| Transport + Authentifizierung    | `sshd`              |
| Discovery + Metadaten            | `abtop`             |
| Komfort-Glue (Eigenanteil)       | 2 Shell-Scripts     |

Der tmux-Server liefert den vom Nutzer ursprünglich skizzierten Lifecycle gratis:
erste Session startet den Daemon, letzte beendet ihn.

**Transport:** reines SSH zu `macbook.local` (Bonjour/mDNS löst in beiden
Netz-Szenarien auf). Kein mosh — lokale niedrige Latenz, und tmux-Persistenz
fängt iPad-Sleep / WLAN-Wechsel ohnehin ab. Die bestehende FritzBox-WireGuard
bleibt als Notnagel für „von ganz außen", ist aber nicht Teil des Kernzwecks.

## Komponenten

### A — `claude-remote` (Launch-Wrapper, läuft am Mac)

Startet `claude` direkt in einer benannten, detached angelegten tmux-Session und
attached anschließend.

**Verhalten:**

- **Default = immer eine *neue* Session** (kein `-A`-Re-Attach). Re-Attach läuft
  über den Picker.
- **Optionales Label:** `claude-remote [label]`.
- **Namensschema:** `<label-oder-basename>-<claude-pid>`
  - ohne Label: `<basename-cwd>-<claude-pid>` (z.B. `projects-49271`)
  - mit Label: `<label>-<claude-pid>` bzw. bei Label-Kollision wird die PID
    angehängt.
- **Disambiguator = Claude-/Pane-PID.** Begründung: garantiert eindeutig ohne
  Scan, **deckungsgleich mit der PID, die `abtop` meldet** → der Join im Picker
  ist ein direkter PID-Vergleich, und bei manuellem `tmux ls` / Troubleshooting
  (`kill`, `ps`, `htop`) ist die relevante, *lebende* PID direkt am Namen ablesbar.
  (Shell-PID `$$` wäre einfacher, zeigt aber auf die — evtl. tote —
  Launcher-Shell und ist nicht deckungsgleich mit abtop.)

**Start-Ablauf („der kleine Tanz"):**

```bash
tmux new-session -d -s "${base}-tmp-$$" -- claude "$@"   # detached, Wegwerf-Name
pid=$(tmux display -p -t "${base}-tmp-$$" '#{pane_pid}') # Claude-PID (= pane_pid)
tmux rename-session -t "${base}-tmp-$$" "${name}-${pid}" # final umbenennen
tmux attach -t "${name}-${pid}"                          # attachen
```

`-- claude` lässt tmux Claude **direkt** in den Pane exec'en (keine
Zwischen-Shell) → `#{pane_pid}` ist sofort die Claude-PID, keine Race Condition.

**Abhängigkeiten:** prüft beim Start, ob `tmux` vorhanden ist; klare Fehlermeldung
sonst.

### B — `claude-remote-pick` (Picker, läuft am Mac; lokal und remote nutzbar)

1. `abtop --json` aufrufen → Sessions mit Metadaten (cwd, Projekt, Tokens,
   Context-%, Modell, PID).
2. `tmux list-sessions` + `list-panes` → ermitteln, welche `pane_pid` (= Claude-PID)
   in welcher tmux-Session steckt → das ist die **attachbare** Teilmenge.
3. **Join** über die Claude-PID (direkter Vergleich, rein lesend).
4. **Menü** rendern: jede attachbare Session mit abtop-Metadaten + Eintrag
   „＋ neue Session".
5. **Schleifen-Verhalten:** Auswahl → `tmux attach` (ohne `exec`). Nach `Ctrl-b d`
   (Detach) landet man wieder im Picker. Ein expliziter „Beenden"-Eintrag schließt
   die SSH-Verbindung.
6. **Fallback:** Fehlt `abtop` oder schlägt das JSON-Parsing fehl (Exit-Code,
   leere/unparsebare Ausgabe) → Liste direkt aus `tmux list-sessions` (reduzierte
   Metadaten, voll funktionsfähig).

**UI:** `fzf` falls installiert (Pfeiltasten/Fuzzy, angenehm in Blink), sonst
nummeriertes `read`-Menü (null Dependencies).

### C — SSH-Eintrittspunkt

Das iPad bekommt einen **eigenen SSH-Key**; dessen Zeile in
`~/.ssh/authorized_keys` erzwingt den Picker:

```
command="claude-remote-pick",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA… ipad
```

So ist der Trigger auf genau diesen Key beschränkt — lokale Terminals und
Admin-SSH bleiben unberührt; ein zweiter, normaler Key bleibt als Wartungs-Bypass.

## Datenfluss

**Lokal starten:** `claude-remote` im Projektordner → tmux-Session anlegen/benennen
→ attach → Claude läuft. Detach/Fenster schließen → Claude läuft weiter.

**Remote verbinden:** Blink → SSH `macbook.local` mit iPad-Key → sshd zwingt
`claude-remote-pick` → Picker (abtop + tmux, Join per PID) → Auswahl → `tmux attach`
→ „als wäre es lokal".

## Edge Cases

| Fall | Verhalten |
|------|-----------|
| Keine Sessions | Picker zeigt nur „＋ neue Session" → fragt nach Verzeichnis (oder Default-Pfad) → startet dort `claude-remote` → attach |
| `abtop` fehlt / Parsefehler | Automatischer Fallback auf `tmux list-sessions` |
| Bare Claude (ohne `claude-remote`, nicht in tmux) | von abtop entdeckt, aber **nicht attachbar** → erscheint als Fußnote „N weitere Claude-Sessions laufen ohne `claude-remote` (nicht attachbar)", nicht im auswählbaren Menü |
| Subagenten / Claude-Kindprozesse | Join matcht den Top-Level-Claude (= `pane_pid`), nicht die Kinder |
| Gleichzeitiges Attach (Mac + iPad) | tmux spiegelt; `aggressive-resize on` → Größe folgt aktivem Client; Rotation/Resize → `SIGWINCH` |
| Reboot | tmux-Server stirbt, Sessions weg (akzeptiert, dokumentiert) |
| Fehlende Dependencies (`tmux`) | `claude-remote` meldet klar beim Start |

> **Nachtrag (nach 2026-06-15):** Ein Keychain-Anker (`cr_ensure_anchor` + per-User-`LaunchAgent`, Branch `tmux-anchor`) kam später hinzu. Er sorgt dafür, dass der tmux-Server in der GUI-(`Aqua`-)launchd-Domain geboren wird, damit neue iPad-Sessions die Login-Keychain schreiben können (sonst scheitert der OAuth-Token-Refresh mit `errSecInteractionNotAllowed (-25308)`). Der `Reboot`-Fall oben wird dadurch beim nächsten GUI-Login automatisch wieder hergestellt. Maßgeblich für den aktuellen Stand sind CLAUDE.md/README, nicht diese datierte Spec.

## Sicherheit

`command="claude-remote-pick"` beschränkt nur den **Eintrittspunkt**. Nach
`tmux attach` hat der Client vollen interaktiven Zugriff (das ist der Zweck). Der
iPad-Key ist daher **faktisch ein Vollzugriffs-Key** und muss wie ein Login-Key
geschützt werden — kein Sandbox-Key. Die `no-*-forwarding`-Optionen härten nur den
Eintrittspunkt.

## Test-Strategie

TDD mit `bats`. Stubs an den Systemgrenzen statt echtem Claude/Netzwerk:

- **Fake-`claude`** (Script, das nur schläft) für deterministische Starts.
- **Fixture-`abtop --json`** statt echtem abtop.
- **Echte, kurzlebige tmux-Sessions** im Test.

Testfälle:

- **Namenslogik:** Start mit Fake-`claude` → Session existiert, Name
  `<base>-<pane_pid>`; Label-Variante; Label-Kollision hängt PID an.
- **Picker-Join:** echte tmux-Session (Stub) + Fixture-abtop-JSON mit
  passenden/nicht-passenden PIDs → korrekter Merge + „nicht attachbar"-Fußnote.
- **Fallback:** `abtop` aus PATH entfernt → `tmux ls`-Fallback greift.
- **Manuelle Abnahme-Checkliste** (nicht automatisierbar): Blink-Round-Trip —
  verbinden → Picker → auswählen → attach → detach → zurück im Picker → beenden.

## Offene Punkte für den Implementierungsplan

- Default-Verzeichnis für „＋ neue Session" aus dem Picker heraus (konfigurierbar?).
- Genaues Format der Picker-Zeile (welche abtop-Felder, Spaltenlayout).
- `fzf`-Integration vs. Zahlenmenü als Code-Pfade.
- Installations-/Setup-Script (Key-Eintrag in `authorized_keys`, tmux-Optionen
  wie `aggressive-resize`).
