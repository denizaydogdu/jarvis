# Jarvis

**English** · [Türkçe](README.tr.md)

Jarvis is a macOS voice assistant for Claude Code. When your terminal agent stops to ask something —
a permission, a choice between options, a check-in when it finishes — a small cat panel appears on
your screen, speaks the question aloud, opens the microphone, listens to your spoken answer and
sends your decision back to the terminal. You never have to walk back to the keyboard; the agent
never has to wait for you in silence.

When it is not practical to speak, the same panel answers with buttons, and when the office server
([Ofis](https://github.com/denizaydogdu/ofis)) is running on the same Mac, Jarvis also speaks
the office's status and its pending decisions out loud, and relays your answers over the A2A
protocol.

Everything runs on your machine: speech recognition and speech synthesis are macOS system services,
the Ofis connection is loopback-only, and the gate key is never stored, logged or echoed.

> **Language:** the panel text, the spoken questions and the spoken answers are in **Turkish**.
> The code identifiers are English; code comments and the developer docs are English too.

## Contents

- [How it works](#how-it-works)
- [What you can say](#what-you-can-say)
- [Ofis connection (A2A)](#ofis-connection-a2a)
- [Requirements](#requirements)
- [Install and update](#install-and-update)
- [Daily use](#daily-use)
- [Privacy and safety](#privacy-and-safety)
- [Running the tests](#running-the-tests)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## How it works

1. `scripts/install.sh` wires the `jarvis-hook` binary into Claude Code's hooks
   (`~/.claude/settings.json` — a backup of your previous settings is printed): `PermissionRequest`,
   `Stop`, and `PreToolUse` for `AskUserQuestion`.
2. When Claude Code fires one of those hooks, `jarvis-hook` sends the question over a local unix
   socket to the Jarvis menu bar app.
3. The panel appears with the project name and the cat, speaks the question with macOS text-to-speech,
   and starts listening. Your microphone input is transcribed by the macOS Speech framework (Turkish
   dictation).
4. Your words become a decision: an allow phrase approves, "hayır" denies, an option label or number
   picks an option, and a question of your own is answered aloud and written back to the transcript.
   The agent continues with your answer as if you had typed it.
5. If you cannot speak — in a meeting, in public — the panel also answers with buttons, and
   "Konuşamam" (or saying it out loud) switches to that button mode for the rest of the day.

## What you can say

Spoken Turkish answers, recognised by intent (not exact wording):

- **Allow:** "izin ver", "onaylıyorum", "evet" — the request is approved.
- **Deny:** "hayır" — the request is denied.
- **Pick an option:** the option's label or its number ("ikinci", "2") answers a choice question.
- **Ask something back:** your own question is answered aloud; the panel hands the conversation to
  the terminal so you can continue by keyboard.
- **"terminal"** hands the question to the terminal immediately, unanswered.
- **"Konuşamam"** switches to button answering mode ("quiet mode") for the rest of the day.

## Ofis connection (A2A)

When the [Ofis](https://github.com/denizaydogdu/ofis) office server is running on the same
Mac, Jarvis discovers its A2A gate by scanning `127.0.0.1:8800–8819` for an Agent Card named
"Ofis", and becomes the office's voice front-end:

- **"Ofis durumu"** (menu) speaks the office's current status aloud.
- **"Ofis kararlarını sor"** (menu, on by default) speaks every decision the office is waiting on
  and records your spoken answer, so the office keeps moving while you are away from the browser.

**Setup on the Ofis side.** The gate is off by default. In Ofis's `ofis.json` set `jarvis.acik` to
`true` and restart the Ofis server; it creates the key file `<Ofis folder>/durum/jarvis_anahtari`
(mode 0600). `jarvis.kapsam` decides what Jarvis may do: `durum-karar` (the default) is enough for
everything above; `durum-karar-is` additionally allows the upcoming "Ofise iş ver" item to hand a
new job to the CEO — which always requires the on-screen "Gönder" button, never voice alone. Ofis
rate-limits the gate (`jarvis.dakika_sinir`, default 60 requests a minute) and answers `429` with
`Retry-After` when the limit is exceeded.

**Where Ofis lives.** Jarvis looks for Ofis in `~/Dev/ajan-ofisi` by default. If you cloned Ofis
somewhere else, write that folder into `~/.jarvis/ofis-dir` (one line, an absolute path; `~` is your
home folder) and restart Jarvis.

The gate key is read from `<Ofis folder>/durum/jarvis_anahtari` before every request, goes only
into the `Authorization` header, is never stored or logged, and is redacted from every gate response
before parsing. The connection is plain HTTP on `127.0.0.1` only: no cookies, no cache, no redirects,
no requests to any other host.

## Requirements

- macOS 14 or newer
- Swift 6 toolchain (`xcode-select --install` is enough)
- Claude Code
- **macOS Dictation ON with the Turkish language**
  (System Settings → Keyboard → Dictation → Turkish)
- Optional: [Ofis](https://github.com/denizaydogdu/ofis) for the office features — Jarvis is optional
  for Ofis and Ofis is optional for Jarvis; both work alone and the office features simply appear
  when both run.

## Install and update

```bash
git clone https://github.com/denizaydogdu/jarvis.git
cd jarvis
scripts/install.sh
```

The script builds the release binaries, installs `Jarvis.app` into `~/Applications`, installs
`jarvis-hook` into `~/.jarvis/bin`, merges the hook entries into `~/.claude/settings.json`
(idempotent — it prints the backup path), quits a running Jarvis and relaunches it.

Note that `~/.claude/settings.json` is the **global** Claude Code settings file: the hooks apply to
**every Claude Code session on the machine**, not to one project. To undo them, restore the backup
the script prints, or remove the `jarvis-hook` entries from `~/.claude/settings.json`.

To update: `git pull && scripts/install.sh`.

## Daily use

The menu bar cat is the whole UI:

- **Sessiz** — mute the voice; the panel still appears and answers still work.
- **Girişte başlat** — launch at login.
- **Ofis durumu** — speak the office status now (Ofis required).
- **Ofis kararlarını sor** — toggle the office decision reader (Ofis required).
- **Rahatsız etme** (30 dakika / 1 saat) — quiet mode: questions are answered with buttons and
  every missed decision is counted; **Devam et** ends it early.

On the panel itself: the copy button puts the whole untruncated question on the clipboard, and the
answer buttons (`Onaylıyorum`, `Hayır`, …) mirror the spoken answers.

## Privacy and safety

- Everything is local: no telemetry, no network except the loopback Ofis gate, no third-party
  speech services — dictation and synthesis are macOS system features.
- The Ofis key is read per request, used only in the `Authorization` header, never logged, and
  redacted from gate responses so an echoing gate cannot leak it either.
- The panel reads Claude Code transcripts from your own home directory. Projects you do not want
  the panel to speak from can be listed line by line in `~/.jarvis/excluded-paths`.

## Running the tests

```bash
swift test
```

Pure Swift tests over the core logic (intent parsing, choice timing, speech text, hooks, the Ofis
client against a mock A2A gate, quiet mode, panel copy) — no network, no microphone needed.

## Troubleshooting

- **The cat is silent / nothing is transcribed:** check System Settings → Keyboard → Dictation is
  ON with Turkish, and that Jarvis has Microphone and Speech Recognition permission
  (System Settings → Privacy & Security).
- **Questions do not appear:** verify the hook entries exist in `~/.claude/settings.json`
  (`jarvis-hook install-settings` merges them back, printing a backup path), and that only one
  Jarvis instance is running.
- **Ofis items do nothing:** on the Ofis side `jarvis.acik` must be `true` in `ofis.json` (a gate
  that is off answers 404 to everything) and the server must be running. Then check the folder:
  when Ofis is not in `~/Dev/ajan-ofisi`, write its folder into `~/.jarvis/ofis-dir` and restart
  Jarvis; it looks for the Agent Card on `127.0.0.1:8800–8819` and the key file at
  `<Ofis folder>/durum/jarvis_anahtari`.

## License

[MIT](LICENSE)
