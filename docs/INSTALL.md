# Installing KickMetrics on an iPhone from a Windows PC

KickMetrics isn't on the App Store. GitHub builds the app file (`.ipa`) on a
cloud Mac; you install it with **Sideloadly** on Windows, signed with your
own free Apple ID. No Mac and no paid developer account are needed.

With a free Apple ID the installed app works for **7 days**, after which you
re-install it (your saved shots stay on the phone). You can have up to 3
sideloaded apps at once.

## One-time setup

### On the PC

1. Install **iTunes** and **iCloud** from Apple's website, not the
   Microsoft Store versions:
   - iTunes: apple.com/itunes → "Windows" → download the 64-bit installer
     for Windows ("Looking for other versions?" link).
   - iCloud: support.apple.com → search "iCloud for Windows" → download
     the installer from Apple's page.

   Sideloadly needs the drivers these install.
2. Install **Sideloadly** from sideloadly.io (Windows version).
3. Plug the iPhone in with a USB cable. On the phone, tap **Trust** and
   enter the passcode. In iTunes, check the phone shows up.

### On the iPhone

4. Turn on **Developer Mode**: Settings → Privacy & Security → Developer
   Mode → on → restart when asked → confirm after restart.

   If Developer Mode isn't listed, do the first install below (step 3 of
   "Installing a build") first; the option appears once a sideloaded app is
   on the phone.

## Installing a build

1. **Download the app.** Open the repository on GitHub → **Actions** tab →
   **iOS build** → the newest run with a green check → scroll to
   **Artifacts** → download **KickMetrics-ipa** (you must be signed in to
   GitHub). Unzip it; inside is `KickMetrics.ipa`.
2. **Install with Sideloadly.** Open Sideloadly, with the iPhone plugged in:
   - Drag `KickMetrics.ipa` onto the IPA box.
   - Choose your iPhone in the device list.
   - Enter your Apple ID email.
   - Press **Start** and enter the Apple ID password when asked.

   The Apple ID login goes to Apple only, to create a free signing
   certificate. It never goes to GitHub or this project.
3. **Trust the app.** On the iPhone: Settings → General → VPN & Device
   Management → your Apple ID under "Developer App" → **Trust**.
4. Open **KickMetrics** and allow camera access.

### Every 7 days

Repeat step 2 with the same `.ipa` (or a newer one). Sideloadly also has an
auto-refresh option that re-signs over Wi-Fi while the PC is on.

## Troubleshooting

- **"Untrusted developer"** when opening the app: do step 3.
- **Sideloadly can't see the phone:** reinstall iTunes from Apple's site (not
  the Store), unlock the phone and tap Trust again.
- **"Maximum number of apps"**: a free Apple ID allows 3 sideloaded apps;
  delete one you don't need.
- **App closes immediately after 7 days:** the signature expired; re-install
  (step 2).
