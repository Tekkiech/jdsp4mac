# Per-app exclusion checklist (human)

About 5 minutes. Open the dev build (`open build/DerivedData/Build/Products/Debug/jdsp4mac.app`), power on, and make an effect obvious (e.g. Reverb on, or Bass boost at max).

- [x] Play music in the Music app (or Spotify), and something else at the same time (a YouTube video in Chrome, or a game). Both have the effect.
- [x] Settings › **Apps** › **Add App Using Audio** › pick the music app. Within a moment the music plays **without** the effect, the other app still **with** it. No dropout or click in either.
- [x] Quit the music app and reopen it, play again: still without the effect.
- [x] Remove it from the list (minus button): the effect is back on the music.
- [x] **Choose App…** works for an app that is not running.
- [x] **Safari**: play a video in Safari and music in another app; exclude Safari. Safari plays without the effect, Mail and other apps keep it.
- [x] **Search browser** (office commun): same, exclude it from the list.
- [x] Optional: exclude an app you use for calls (Zoom, FaceTime, Discord) and make a call.

## Report back

For each box: pass, or what you heard.
