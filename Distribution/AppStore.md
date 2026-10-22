# App Store submission

Text and settings for App Store Connect. One app record (bundle id `com.aroneus.kvmclient`)
covers iPhone, iPad and Mac (universal purchase).

## App information

| Field | Value |
|---|---|
| Name | KVM Client *(if taken: "KVM Client – IP-KVM Viewer")* |
| Subtitle (30) | Remote screen for your IP-KVM |
| Subtitle FR | L'écran de votre IP-KVM |
| Primary category | Utilities |
| Secondary category | Developer Tools |
| Price | Free |
| Age rating | 4+ (no objectionable content) |
| Privacy policy URL | https://github.com/dumanhaydar/kvmclient/blob/main/PRIVACY.md |
| Support URL | https://github.com/dumanhaydar/kvmclient/issues |
| Marketing URL | https://github.com/dumanhaydar/kvmclient |
| Copyright | 2026 Haydar Duman |

**App Privacy:** *Data Not Collected.*
**Export compliance:** answered in the build (`ITSAppUsesNonExemptEncryption = NO`, standard TLS/DTLS only).

## Keywords (100 characters max)

```
kvm,ip kvm,kvm over ip,remote,bios,server,homelab,webrtc,jetkvm,pikvm,nanokvm,tinypilot,picokvm
```

FR:
```
kvm,ip kvm,écran distant,bios,serveur,homelab,webrtc,jetkvm,pikvm,nanokvm,tinypilot,picokvm
```

> Brand names are only used to describe compatibility. If review objects (guideline 2.3.7),
> drop them from the keywords and keep them in the description.

## Promotional text (170)

EN: Control any computer through your IP-KVM — BIOS included — with hardware-decoded video, every shortcut captured, and touch gestures made for iPhone.

FR : Pilotez n'importe quel ordinateur via votre IP-KVM, BIOS compris : vidéo décodée par le matériel, tous les raccourcis capturés, gestes tactiles pensés pour l'iPhone.

## Description — English

KVM Client is a fast, fully native app for open-source IP-KVMs. See the screen of another computer and use its keyboard and mouse from your iPhone, iPad or Mac — from power-on and BIOS to the desktop.

WORKS WITH
• Luckfox PicoKVM and JetKVM
• PiKVM, BliKVM and Geekworm KVMs
• Sipeed NanoKVM and NanoKVM-Pro
• TinyPilot
The device type is recognized automatically, and Search the network finds your KVMs for you.

FEELS LIKE SITTING IN FRONT OF IT
• Hardware-decoded video over WebRTC, H.264 or MJPEG
• The Mac window takes the exact shape of the remote screen
• Absolute pointer mapped to the real picture, even when zoomed

EVERY KEY, EVERY SHORTCUT
• On the Mac, ⌘Tab, ⌘Q and friends go to the remote computer, not to macOS
• Positional keys: the remote computer keeps its own layout (AZERTY, QWERTZ…)
• Paste text as keystrokes in 20 PC keyboard layouts
• Ctrl+Alt+Del and other combos one click away

MADE FOR TOUCH
• Drag to scroll, tap then drag to select or move windows
• Pinch to zoom up to 6×, two-finger tap to right-click
• Virtual keyboard with Esc, Tab, sticky Ctrl/Alt/Win, arrows and F1–F12
• Hardware keyboards and iPad trackpads work natively

ANYWHERE, PRIVATELY
• Tailscale and ZeroTier addresses are learned from the device and tried automatically
• Passwords stay in the Keychain; no account, no tracking, no data collected
• Open source under the MIT license

An IP-KVM device is required. KVM Client is not affiliated with the makers of the devices above.

## Description — Français

KVM Client est une app rapide et 100 % native pour les IP-KVM open source. Affichez l'écran d'un autre ordinateur et utilisez son clavier et sa souris depuis votre iPhone, iPad ou Mac, du démarrage et du BIOS jusqu'au bureau.

COMPATIBLE AVEC
• Luckfox PicoKVM et JetKVM
• PiKVM, BliKVM et les KVM Geekworm
• Sipeed NanoKVM et NanoKVM-Pro
• TinyPilot
Le type d'appareil est reconnu automatiquement, et « Rechercher sur le réseau » trouve vos KVM pour vous.

COMME SI VOUS ÉTIEZ DEVANT
• Vidéo décodée par le matériel en WebRTC, H.264 ou MJPEG
• Sur Mac, la fenêtre prend exactement la forme de l'écran distant
• Pointeur absolu calé sur l'image réelle, même zoomée

TOUTES LES TOUCHES, TOUS LES RACCOURCIS
• Sur Mac, ⌘Tab, ⌘Q et les autres vont à l'ordinateur distant, pas à macOS
• Touches positionnelles : l'ordinateur distant garde sa disposition (AZERTY, QWERTZ…)
• Collez du texte sous forme de frappes, dans 20 dispositions de clavier PC
• Ctrl+Alt+Suppr et autres combinaisons en un clic

PENSÉ POUR LE TACTILE
• Glissez pour faire défiler, touchez puis glissez pour sélectionner ou déplacer
• Pincez pour zoomer jusqu'à 6×, touchez à deux doigts pour un clic droit
• Clavier virtuel avec Échap, Tab, Ctrl/Alt/Win maintenus, flèches et F1–F12
• Claviers physiques et trackpads iPad pris en charge

PARTOUT, EN TOUTE CONFIDENTIALITÉ
• Les adresses Tailscale et ZeroTier sont apprises du KVM et essayées automatiquement
• Mots de passe dans le trousseau ; aucun compte, aucun suivi, aucune donnée collectée
• Open source sous licence MIT

Un IP-KVM est nécessaire. KVM Client n'est pas affilié aux fabricants des appareils cités.

## Notes for App Review

```
KVM Client is a viewer for IP-KVM hardware (small network devices that capture another
computer's HDMI output and emulate its USB keyboard and mouse).

To try it without hardware, tap "Try the Demo" on the first screen: it adds a simulated
device showing a Linux server desktop. Type in its terminal (try "help"), drag its windows by
the title bar, scroll, tap/click. A video with a real Luckfox PicoKVM is here: <VIDEO URL>.

- Local Network: used to reach the user's KVM and, on request, to find KVMs on the LAN.
- NSAllowsArbitraryLoads: these devices are reached by IP address or Tailscale/ZeroTier name,
  over plain HTTP or HTTPS with a self-signed certificate generated by the device. Self-signed
  certificates are trusted only for the host the user entered.
- No account, no data collection. The Mac App Store build is sandboxed and does not use the
  Accessibility API.
```

## Screenshots

Ready to upload in [`Screenshots/en`](Screenshots/en) and [`Screenshots/fr`](Screenshots/fr):
iPhone 6.3" (2622 × 1206 and 1206 × 2622), iPad 13" (2064 × 2752), Mac (1440 × 900).
All show the demo device. Mac captions: "All your KVMs in one app" / "Your server, as if you were
right there" (FR: "Tous vos KVM dans une seule app" / "Votre serveur, comme si vous étiez devant").

Product page header (*En-tête*): [`Header/`](Header), 5244 × 2950 and 3840 × 1646, without text so
the same image serves every language. Regenerate with `Distribution/render-header.sh`.

To retake them:

- iPhone and iPad: `Distribution/take-screenshots.sh [en fr]` (simulators, launch arguments
  documented in `KVMUI/App/Screenshots.swift`).
- Mac: run a Debug build with `-screenshots -openDemo [-sidebar | -demoCommand neofetch]`
  (add `-AppleLanguages "(fr)"` for French), capture
  the window at 1360 pt wide, then
  `swift Distribution/compose-mac-screenshot.swift window.png "Caption" out.png`.

## Releasing

Everything goes through [`Taskfile.yml`](../Taskfile.yml) ([go-task](https://taskfile.dev)).
One-time setup: `cp .env.example .env` and fill in the App Store Connect API key.

1. `task version -- 1.1` for a new version (the build number is the commit count), commit, push.
2. `task appstore` — archives iOS and Mac, validates with Apple, asks, uploads.
3. In App Store Connect: pick the builds, fill in "What's New", submit for review.
4. `task direct` then `task github:release` — notarized DMG of the full Mac app on GitHub.

`task release` runs all of it. Each publishing step asks for confirmation (`task --yes` skips it).
