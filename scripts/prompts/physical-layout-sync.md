# Nightly task: reconcile physical-layout.md

You are running headless inside the nightly diagram job, in
`~/git/ludorl82`, with the four private IaC repos and net-cfgs checked out.
A previous session has just reconciled `net-cfgs/network-diagram.md`
against the repos, so it is the freshest description of the lab that
exists.

## Your one deliverable

Edit `net-cfgs/physical-layout.md` — and ONLY that file — so it no longer
contradicts what the repos and `network-diagram.md` say. Do not commit; the
driver commits exactly that file after you finish.

## The line you must not cross

This document describes **physical reality**: which box sits in which rack,
what is plugged into which UPS, cable runs, port counts, hardware models.
**Nothing you can read proves or disproves any of that** — no repo knows
where a machine physically sits. Leave every such statement exactly as it
is, even if it looks odd.

What you *can* check is **identity and existence**:

- a machine named here that no longer exists under that name anywhere
  (the 2026-08-05 reimage and the 2026-08-07 jumphost/console split both
  moved names between boxes — that class of error is why this task exists);
- a machine described as running something it no longer runs;
- a host listed as part of the cluster that is not, or missing from it;
- counts that disagree with the repos (how many Pis, how many nodes);
- a name that has been superseded by a rename.

When identity changed but the *box* did not move, say so in place: the
hardware is still in that rack slot, it simply answers to a different name
now, and the sentence should read as one fact rather than two.

## Hard rules

1. Touch only `net-cfgs/physical-layout.md`.
2. Cite your evidence to yourself before each edit: point to a specific
   file (a repo config, or a line of `network-diagram.md`) that contradicts
   the sentence you are rewriting. No evidence, no edit.
3. Fix in place — this file is present-tense state. Never append an update
   block or a dated narrative; that habit is what made the previous version
   of its sibling untrustworthy.
4. This is a PRIVATE file — real hostnames and addresses belong here. Do
   not sanitize anything.
5. If a statement is about physical reality and merely *looks* stale, leave
   it and mention it in your report instead. A human with eyes on the rack
   is the only one who can settle those.

Report at the end, one short paragraph per change: what contradicted what
(file vs file), and what you rewrote. List separately anything you
suspected but left alone for rule 5. If nothing contradicted, say so in one
line.
