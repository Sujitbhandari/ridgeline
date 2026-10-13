# Postmortem: <short title>

Blameless. The question is never "who", it's "what about the system made this
easy to do and hard to notice".

| | |
|---|---|
| Date | |
| Duration (detect → mitigate → resolve) | |
| Severity / error budget consumed | |
| Services affected | |
| Author(s) | |

## Summary

Two or three sentences a director can read in 20 seconds: what broke, who was
affected, how long, and the one change that prevents it.

## Impact

Requests failed, latency, customers affected. Use numbers from Prometheus, not
estimates. Link the dashboard with the incident window selected.

## Timeline (UTC)

| Time | Event |
|---|---|
| | First signal (alert / customer / engineer) |
| | Acknowledged |
| | Hypothesis 1 ... |
| | Mitigation applied |
| | Recovered |

## Root cause and trigger

Separate the **trigger** (what changed) from the **root cause** (why the
system allowed that change to hurt users).

## Detection

Did the right alert fire at the right time? If a human noticed first, that's an action item.

## What went well / what was hard

## Action items

| Action | Type (prevent / detect / mitigate) | Owner | Ticket |
|---|---|---|---|
| | | | |

Prefer actions that change the platform (a default, a policy, an alert) over
actions that ask people to remember something.
