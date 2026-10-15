# brave-profiles

A fast macOS Chromium profile switcher for [Tern](https://docs.stencil.so/tern/).
Choosing a profile from any supported installed browser (Chrome, Brave, Edge
and others below) opens it **inside Tern**: a named, isolated Tern browser
signed in with that profile's cookies, in a normal split beside your pane.
Nothing launches Chrome or Brave. The plugin id remains `brave-profiles`.

## Open a profile in Tern

Press **⌥⇧B** (`alt+shift+b`) to pick a profile, or type its name in the
palette: every profile has a command such as **Chrome: Work**.

Each source profile gets its own persistent Tern browser profile, named
`brave-profiles:<browser>/<profile folder>` (for example
`brave-profiles:chrome/Default`). Its cookies, sign-ins and site data stay
separate from every other profile and from Tern's default browser.

- **First open:** the plugin copies *all* of the source profile's live
  cookies into that isolated Tern profile, then loads the page (Google when
  nothing else was asked for). Decrypting the cookies reads the source
  browser's Keychain item, so macOS may ask you to allow it. If the copy
  fails or you deny the Keychain prompt, the blank browser is closed, a
  message says why, and the next open tries again.
- **Later opens:** the same persistent Tern profile opens straight away,
  with whatever it has kept; nothing is copied and the Keychain is not read.
- **Copy sign-ins again…** picks a profile and recopies its current cookies
  into that profile's Tern browser only (never into whichever browser happens
  to be focused). Use it after signing in to something new in the source
  browser: the copy is one-off, not continuous mirroring, and nothing is
  deleted from the Tern profile.

What is copied is cookies only. Tern uses its own native embedded browser
engine, not Chrome's, so extensions, saved passwords, bookmarks, history and
local storage are not carried over, and source profiles are never modified.
Most cookie-based sign-ins carry over, but not every site: sites that bind a
session to the device, to local storage or to the original browser may ask
you to sign in again.

Commands speak about the browsers you actually use. If all your profiles
are Chrome's, the commands are **Chrome: Open profile in Tern…**, **Chrome:
Open Tern's links in a profile…** and **Chrome: Copy sign-ins again…**, and
the picker is a plain list of your Chrome profiles. With profiles in several
browsers the commands start with **Browser:** and the picker groups profiles
by browser, the one you used most recently first. Each row shows the
profile's signed-in account. The picker reads profiles fresh each time, so a
new profile appears without reloading plugins; its own command arrives with
the next window.

A browser counts when its app is in `/Applications` or `~/Applications`
and it has been run at least once (its `Local State` file holds the profile
names, order and signed-in addresses; a malformed file hides only that
browser).
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
| Helium | `Helium.app` | `net.imput.helium` | `Helium Storage Key` |
| Yandex | `Yandex.app` | `Yandex/YandexBrowser` | `Yandex Safe Storage` |
| Naver Whale | `Whale.app` | `Naver/Whale` | `Whale Safe Storage` |

Data directories are relative to `~/Library/Application Support`.

## Route links

Use **Open Tern's links in a profile…** to send Tern's plain HTTP(S) link
clicks to a profile: each opens in that profile's Tern browser, exactly like
opening the profile yourself (including the first-time cookie copy). Choose
**Tern** (the first row, ticked while nothing is routed) to stop. Clicking
with ⌘, ⌥, ⇧ or ⌃ held, or a non-HTTP(S) link, bypasses routing and opens
the link in Tern as usual. If the routed profile's folder disappears, routing
is cleared and links open normally.

## Cookie copy details

The exporter reads `<profile>/Network/Cookies` or `<profile>/Cookies` from a
copy in a private temporary directory, since the source browser may keep it
locked. It runs `export_cookies.py` with system `/usr/bin/python3` and
decrypts values using the source browser's own Keychain item from the table
above, never another browser's. Expired cookies are skipped first, and the
Keychain is read only when a live encrypted cookie remains, so a profile
with no cookies (or none needing decryption) never prompts.

Cookies go only to the chosen profile's isolated Tern browser (`setCookie`).
No cookie values are logged, and nothing is written to disk besides the
temporary database copy and its SQLite sidecars, which are removed on exit.
No other profile data (history, passwords, local storage) is read. Session
cookies are credentials: anything that can drive that Tern browser profile
can use them until they expire.

The exporter can also be invoked from the plugin directory:

```sh
# every live cookie of the profile (what opening a profile uses)
/usr/bin/python3 export_cookies.py --data 'Google/Chrome' \
  --keychain 'Chrome Safe Storage' Default --all
# only one site's cookies
/usr/bin/python3 export_cookies.py --data 'Google/Chrome' \
  --keychain 'Chrome Safe Storage' Default app.example.com
```

Give exactly one of `--all` or a HOST. With a HOST only that host's *site*
is exported: the host and sibling subdomains of the same site, using the last
two host labels (three under e.g. `.co.uk`), a heuristic rather than the
public suffix list. It prints a JSON cookie array to stdout; `--summary`
prints only per-domain counts and how many cookies could not be decrypted,
never cookie values. With `--all`, a profile folder that has no cookie
database yet prints `[]`. Errors go to stderr with a nonzero exit status:
a missing profile folder, and encrypted cookies none of which decrypt with
the browser's Keychain key (a wrong key would otherwise import only the few
unencrypted cookies and look like a sign-in that did nothing).

## The block

Choose **New Browser Profiles block** in the palette to keep a list of every
profile in a pane. It shows each profile's signed-in account, and its
browser when your profiles span several.

- `↑` / `↓` or `k` / `j`: move the selection.
- `Home` / `End`: jump to the first or last profile.
- `⏎` (Enter), or double-click: open the selected profile in Tern.
- `l`: route links to the selected profile; press again to stop routing.
- `r`: refresh the profile list.

## Where things run

Palette commands, link routing, cookie copies and the Tern browsers they open
all run in each window, using the browsers, profile files and Keychain on the
machine showing that window. The block lists profiles from the machine that
runs your panes; pressing Enter there hands the open to the window, so on a
remote session the profile must also exist on the window's machine, or the
window says it cannot be found. On a local desktop these are the same
machine. The routing choice and which profiles have had their sign-ins
copied are shared through the plugin's key/value store, so every window
behaves the same way.

## Install

From the folder that holds this package:

```sh
tern plugin install brave-profiles
```

Or load it in place and reload on every save:

```sh
tern plugin link "$(pwd)/brave-profiles"
```
