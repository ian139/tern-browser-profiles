# brave-profiles

A fast macOS Chromium profile switcher for [Tern](https://docs.stencil.so/tern/).
Open profiles from any supported installed browser, route Tern links to a
profile, or explicitly copy a site's cookies into Tern's browser. The plugin
id remains `brave-profiles`.

## Open a profile

Press **⌥⇧B** (`alt+shift+b`) or choose **Open browser profile…** in the
palette. The picker groups profiles by browser and shows their signed-in
accounts. It reads fresh profile information when opened, so newly created
profiles appear without reloading plugins. Direct palette commands named
**<Browser>: <profile>** open individual profiles without the picker.

A browser is installed when its app bundle exists in `/Applications` or
`~/Applications`. Profile names, order and signed-in addresses come from
its `Local State`; a missing or malformed file hides only that browser.
Supported browsers and their storage locations are:

| Browser | App bundle | Data directory | Keychain item |
| --- | --- | --- | --- |
| Brave | `Brave Browser.app` | `BraveSoftware/Brave-Browser` | `Brave Safe Storage` |
| Brave Beta | `Brave Browser Beta.app` | `BraveSoftware/Brave-Browser-Beta` | `Brave Safe Storage` |
| Brave Nightly | `Brave Browser Nightly.app` | `BraveSoftware/Brave-Browser-Nightly` | `Brave Safe Storage` |
| Chrome | `Google Chrome.app` | `Google/Chrome` | `Chrome Safe Storage` |
| Chrome Beta | `Google Chrome Beta.app` | `Google/Chrome Beta` | `Chrome Safe Storage` |
| Chrome Dev | `Google Chrome Dev.app` | `Google/Chrome Dev` | `Chrome Safe Storage` |
| Chrome Canary | `Google Chrome Canary.app` | `Google/Chrome Canary` | `Chrome Safe Storage` |
| Chromium | `Chromium.app` | `Chromium` | `Chromium Safe Storage` |
| Edge | `Microsoft Edge.app` | `Microsoft Edge` | `Microsoft Edge Safe Storage` |
| Edge Beta | `Microsoft Edge Beta.app` | `Microsoft Edge Beta` | `Microsoft Edge Safe Storage` |
| Edge Dev | `Microsoft Edge Dev.app` | `Microsoft Edge Dev` | `Microsoft Edge Safe Storage` |
| Edge Canary | `Microsoft Edge Canary.app` | `Microsoft Edge Canary` | `Microsoft Edge Safe Storage` |
| Vivaldi | `Vivaldi.app` | `Vivaldi` | `Vivaldi Safe Storage` |
| Helium | `Helium.app` | `net.imput.helium` | `Helium Storage Key` (assumed) |

Data directories are relative to `~/Library/Application Support`. Helium's
Keychain item name is an assumption; cookie import needs that item to exist.

## Route links

Use **Route links to a browser profile…** (the `links` palette picker) to
choose a profile for Tern's plain HTTP(S) link clicks. Choose **Tern (stop
routing)** to stop. Clicking with ⌘, ⌥, ⇧ or ⌃ held bypasses routing and
opens the link in Tern instead.

## Sign a Tern page in

Focus a Tern browser block and use **Sign this Tern page in from a browser
profile…** (the `import` palette picker) to select a profile. The plugin
copies that page's *site* cookies into Tern's browser
and reloads the page. It includes the host and sibling subdomains of the
same site so SSO redirects work. This happens only when explicitly requested
and is a one-off copy: later sign-ins in the source browser need another import.
Tern's browser otherwise starts signed out, the right default for agents
driving it.

The exporter reads `<profile>/Network/Cookies` or `<profile>/Cookies` using
a temporary database copy, since the source browser may keep it locked.
It runs `export_cookies.py` with system `/usr/bin/python3` and decrypts values
using the source browser's Keychain item in the table above. macOS may prompt
you to allow that Keychain read.

Cookies go only to Tern's browser (`setCookie`). No cookie values are logged,
and nothing is written to disk besides the temporary database copy and its
SQLite sidecars, which are removed on exit. No other profile data (history,
passwords, local storage) is read. The cookie store is shared by every Tern
browser block, and session cookies are credentials: anything that can drive
Tern's browser can use them until they expire. Site matching uses the last
two host labels (three under e.g. `.co.uk`), a heuristic rather than the
public suffix list.

The exporter can also be invoked from the plugin directory:

```sh
/usr/bin/python3 export_cookies.py --data 'Google/Chrome' \
  --keychain 'Chrome Safe Storage' Default app.example.com
```

It prints a JSON cookie array to stdout; `--summary` prints only per-domain
counts, never cookie values. Errors go to stderr with a nonzero exit status.

## The block

Choose **Open browser profiles block** to keep a **Browser Profiles** list
in a pane (one per window). It groups profiles by browser and displays
signed-in accounts.

- `↑` / `↓` or `k` / `j`: move the selection.
- `Home` / `End`: jump to the first or last profile.
- `⏎` (Enter), or double-click: open the selected browser profile.
- `l`: route links to the selected profile; press again to stop routing.
- `r`: refresh the profile list.

## Where things run

The block runs in the session daemon's plugin half, so its launches open the
browser on the machine that runs your panes. Palette commands, cookie imports
and link routing run in each window, using the browsers, profile files and
Keychain on the machine showing that window. On a local desktop these are the
same machine. The routing choice is shared through the plugin's key/value
store, so every window routes the same way.

## Install

From the folder that holds this package:

```sh
tern plugin install brave-profiles
```

Or load it in place and reload on every save:

```sh
tern plugin link "$(pwd)/brave-profiles"
```
