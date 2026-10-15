# brave-profiles

Your [Brave](https://brave.com) profiles in
[Tern](https://docs.stencil.so/tern/): a launcher block, three palette
commands per profile (open, route links, import cookies), and optional
link routing into a chosen profile.
macOS only (it launches the Brave bundle and reads Brave's `Local State`
on the machine it runs from).

Profile names and signed-in addresses come from Brave's `Local State`.
Cookies are read only by the explicit import command below; no tokens or
history are touched.

## The block

Palette: **Brave › Open Brave profiles** (bound to `alt+shift+b`), or
"New Brave Profiles block". One per window.

- `↑`/`↓` (or `k`/`j`), `Home`/`End` move.
- `Enter` (or double-click) opens Brave in the selected profile.
- `l` routes Tern's http(s) link clicks to the selected profile (press
  again to stop). Click a link with ⌘, ⌥, ⇧ or ⌃ held to open it in Tern
  instead.
- `r` reloads the block's profile list.

## Palette commands

- **Brave: Open \<profile\>** — one per profile, opens Brave in it.
- **Brave: Links open in \<profile\>** — same routing choice as `l`.
- **Brave: Links open in Tern** — stops routing (only shows while a
  profile owns links).
- **Brave: Sign this Tern page in with \<profile\> cookies** — one per
  profile; see below.

Commands are registered when a window starts: after making a new Brave
profile, reload plugins (`tern plugin reload`) or open a new window to
get its commands; `r` only refreshes the block's list.

## Signing a Tern page in

Tern's browser starts signed out, which is the right default for agents
driving it. Focus a Tern browser block and run the palette command above
to copy that page's *site* cookies (its host and every other subdomain of
the same site, so SSO redirects work) from the chosen profile into Tern's
browser, then reload the page. Nothing happens unless you run it, and it
is a one-off copy: later sign-ins in Brave need another run.

It reads `<profile>/Cookies` (a temporary copy, since Brave locks it) and
decrypts the values with the `Brave Safe Storage` Keychain key via
`export_cookies.py` (system `python3`); macOS may ask you to allow that
Keychain read. Cookies go only to Tern's browser (`setCookie`); nothing is
written to disk besides the temporary copy, and no other profile data
(history, passwords, local storage) is read. The cookie store is shared by
every Tern browser block, and session cookies are credentials: anything
that can drive Tern's browser can use them until they expire. The site is
its last two host labels (three under e.g. `.co.uk`), a heuristic rather
than the public suffix list.


## Where things run

The block runs in the session daemon's plugin half, so its launches open
Brave on the machine that runs your panes. The palette commands and link
routing run in each window, so they open the Brave of the machine showing
the window (on the desktop that is the same machine). The routing choice
is shared through the plugin's key/value store, so every window routes
the same way.

## Install

From the folder that holds this package:

```sh
tern plugin install brave-profiles
```

or, to load it in place and reload on every save:

```sh
tern plugin link "$(pwd)/brave-profiles"
```
