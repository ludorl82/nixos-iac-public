# Nightly task: reconcile network-diagram.md with the IaC repos

You are running headless inside the nightly diagram job (Session A), in
`~/git/ludorl82`, with the four private IaC repos (nixos-iac, k3s-iac,
cloud-01-iac, cloudflare-iac) and net-cfgs checked out at origin HEAD. The
job's drift gate has already confirmed the repos match the live
infrastructure tonight, so "what the repos say" and "what is running" are
the same thing.

## Your one deliverable

Edit `net-cfgs/network-diagram.md` — and ONLY that file — so it no longer
contradicts the repos. Do not commit; the driver script commits exactly
that file after you finish.

## How to work

- The file's own convention (its header) applies to you: **current state
  only, fix in place** — rewrite the wrong sentence or mermaid node, never
  append an update block or a dated narrative.
- Look for contradictions, not omissions: hosts that changed role, services
  that moved node, retired components still described, counts that are off,
  mermaid nodes/edges that no longer exist in the manifests or configs.
  Adding brand-new sections is out of scope.
- If you find no contradiction, change nothing and say so.
- Check the mermaid blocks especially — they carry hostnames, IPs, pins and
  paths that all have a source of truth in one of the four repos.

## Hard rules

1. Touch only `net-cfgs/network-diagram.md`.
2. **Never modify the "Last verified against the live network" line** — it
   is human-owned. Instead, create or update a line directly below it:
   `Last reconciled against the IaC repos: YYYY-MM-DD (automated).`
3. This is a PRIVATE file — real hostnames and addresses are correct here;
   do not sanitize anything.
4. Cite your evidence to yourself before each edit: only change a statement
   you can point to a specific file in a repo contradicting it. When the
   repos are silent on a claim (physical cabling, historical notes, Kuma
   monitor numbers), leave it alone.
5. Keep edits minimal and surgical; preserve the file's voice and layout.

Report at the end, in one short paragraph per change: what contradicted
what (file vs file), and what you rewrote. If nothing contradicted, one
line saying the doc already matches the repos.
