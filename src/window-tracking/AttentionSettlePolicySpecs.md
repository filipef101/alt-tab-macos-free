# Attention settle — Specs

The rule that decides which of an app's accessibility answers reaches `AttentionModel`. Pure: arrivals in,
a deadline and a verdict out. `AttentionEngine` owns the timer and calls this.

## Why it exists

An app raising all of its windows answers once per window, 29ms apart (#5974, measured). Every answer is
true and the user went nowhere — the app puts keys back where they started. Committing each one walked the
app's whole set to the top of the MRU, seen live. Taking only the LAST answer per process is right for that
case and for a genuine switch alike, so the rule is "wait until the app stops talking", and it needs nothing
guessed in advance and taken back.

Since the attention rework this is **the only thing standing between a multi-answer burst and a scrambled
order** — no other rule looks at runs of events any more.

## The rule

- an answer supersedes whatever that process had pending, **including its deadline** — otherwise a run
  commits `settle` after its FIRST member rather than after its last
- every answer carries the process generation and ingress sequence allocated when AX delivered it; settling
  delays commitment without redating the evidence behind a click that arrived during the delay
- a deadline is identified by that unique ingress sequence, so a timer left over from a superseded answer
  commits nothing even if two offers share the same clock reading
- state is per process: one app's burst never delays another app's answer
- a process exit drops its pending answer, so a reused pid inherits nothing

Recent hardware input uses a 60ms settle, a little over the measured 29ms spacing. With no key or mouse
event in the last 500ms, the answer is programmatic and settles for 200ms. That collapses A-11's measured
150ms raise sequence without adding latency to genuine user navigation.

## Test scenarios

- **testARunOfAnswersCommitsOnceWithTheLastWindow** — #5974's shape: four answers 29ms apart collapse to one
  commit, naming the window the run ended on.
- **testASupersededTimerCommitsNothing** — the timer from an overtaken answer fires and is refused; without
  this the run commits once per member after all.
- **testTheDeadlineIsPushedBackByEachAnswer** — the deadline follows the LAST answer, not the first, which is
  what makes a run collapse instead of committing mid-burst.
- **testAQuietAnswerCommitsItself** — one answer with nothing after it is not a burst and commits normally.
- **testTwoAppsSettleIndependently** — a talkative app does not hold up a quiet one's answer.
- **testAProcessExitDropsItsPendingAnswer** — and a reused pid inherits nothing.
- **testRecentInputSelectsTheShortSettle** — input recency chooses latency rather than changing verdicts.
- **testAProgrammaticRunSpaced150msApartCommitsOnce** — A-11's wider raise still ends on its last answer.

The cross-policy integration case lives in `AttentionDriverTests`:
`AX(B2) → exact click(B1) → AX timer fires` leaves B1 in front because the delayed AX offer retains its
earlier sequence.
