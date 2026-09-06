v0.1.20 (next)

- Tweak: the current account's email is now hidden behind a "Show email" label, so it isn't on screen by default (handy when sharing a screen). Click to reveal, click the email to hide it again, and click the copy icon beside it to copy. Reopening the menu bar hides it again.
- Fix: Claude Code no longer gets logged out by ccdeck. ccdeck kept its own copy of the signed-in account's token and refreshed it when it expired — but refreshing rotates the token, which invalidated the one Claude Code was holding and forced you to sign in again. ccdeck now reads the token Claude Code has already refreshed instead of refreshing it itself. Accounts you aren't signed into are unaffected: ccdeck still refreshes those, now shortly before they expire rather than after, so their usage doesn't blank out for a poll.
- Fix: usage keeps working after the Mac has been left alone. Claude Code only refreshes its token while something is running, and its background helper quits when idle — so after a weekend away the token was simply dead, and ccdeck showed "needs re-login" until you started a session. ccdeck now renews it in that case and hands the fresh token back to Claude Code, so the next session doesn't ask you to sign in. It only does this when no Claude Code process is running, so it can never rotate a token out from under a live session.
- Fix: each model now keeps the same colour in the usage chart. Colors used to be assigned by position, so a model changed colour when you switched between today / 7-day / 30-day. A model's colour is now derived from its name and remembered, including across restarts and as new models appear.

v0.1.19

- Tweak: the hover hint now reads in blue with a ⇄ icon, so it's clearer that the row is clickable. Click anywhere on an account row to switch to it.

v0.1.18

- Fix: switching accounts no longer sets off repeated keychain password prompts in every Claude Code session you have open.
