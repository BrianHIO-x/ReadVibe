# App icon

`readvibe-icon.png` is the 1024px master for the launcher icon: a flat cream open
book on the app's terracotta accent `#B3543A`, matching `lib/theme/app_theme.dart`.

It is drawn from vector shapes by `tool/draw_launcher_icon.py`, so it is edited by
changing that script, never by retouching the PNG.

```bash
python tool/draw_launcher_icon.py --install
```

That regenerates the master plus every Android asset:

| Output | Role |
| --- | --- |
| `design/readvibe-icon.png` | 1024px master / store listing source |
| `android/.../mipmap-*/ic_launcher.png` | legacy launchers, opaque square, mark at 58% of canvas |
| `android/.../drawable-nodpi/readvibe_mark.png` | adaptive-icon foreground, transparent, mark inside the 66dp safe circle |

The adaptive icon pairs that foreground with `launcher_background` in
`android/app/src/main/res/values/colors.xml`; keep that colour in sync with
`GROUND` in the script.
