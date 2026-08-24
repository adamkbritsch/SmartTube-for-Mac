# plexmap-verify

Checks `PlexKeyMap.swift` against its two sources of truth, both read live from this Mac:

- `/Applications/Plex HTPC.app/Contents/Resources/inputmaps/keyboard.json` — the SHIPPED map.
  Online sources (including Plex's own support article and the plex-media-player GitHub repo)
  document the predecessor app and are wrong in places (PgUp/PgDn inverted, obsolete modifier
  naming), so the app's table is transcribed from this file and must keep matching it.
- HIToolbox `Events.h` — the authoritative macOS virtual key codes.

The script parses the Swift table out of the real source file (no duplicated fixture), resolves
each keyCode to its key name via Events.h, and compares the mapped action against what Plex binds
to that key. Long-press pairs (Return→menu, Back→home) are checked too.

```
python3 verify_plexmap.py
```

Exit 0 + "ALL MATCH" or a list of mismatches. Run it after ANY edit to PlexKeyMap.swift.
Known deliberate exceptions are skipped inside the script with a comment (keypad +/-, which have
no Plex spelling and share the =/- intent).
