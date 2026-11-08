# Connected repositories and deploy keys

Agent Manager GD launches agents on repositories **you** create (GitHub, GitLab, any SSH git host). Each connected
repository gets its own SSH **deploy key**: a key that opens that repository only.

## Connect a repository

1. Create the repository on GitHub (or elsewhere).
2. In Agent Manager: **⎇ Repos → Add a repository**: its SSH address (`git@github.com:owner/repo.git`) and, if you
   want, the local folder where it is (or should be) cloned. Without a folder, it is cloned on first use into
   Agent Manager's data folder (`~/.local/share/agent-manager-gd/repos/<name>`).
3. Agent Manager makes an ed25519 key for that repository and shows its **public** key. **Copy the public key**, then
   **Open GitHub's Deploy keys page** (or *Settings → Deploy keys → Add deploy key* on the repository): paste it, give it
   a title, tick **Allow write access** (agents push their branch with it), save.
4. Back in Agent Manager: **Check**. « connected » means the key reaches the repository.

## Work on it

**New session** → *Repository*: pick it. The session works in the repository's folder (a git worktree per session if
you tick « In its own git branch »), and every git command in that session uses the repository's key only
(`GIT_SSH_COMMAND` with `IdentitiesOnly=yes`), never your personal SSH keys. The card shows « ⎇ <repository> ».

## Where things are, and what never happens

| What | Where |
|---|---|
| Private key | `~/.local/share/agent-manager-gd/keys/<id>/id_ed25519` (mode 0600, readable by you only) |
| Public key | same folder, `id_ed25519.pub` (safe to share) |
| Host keys seen | `~/.local/share/agent-manager-gd/keys/known_hosts` (accepted on first use) |
| Records | the engine database (address, folder, fingerprint, dates, sessions) — never the private key |

The private key is never printed, logged, sent anywhere or written into a repository.

## Rotate, disconnect

- **Rotate the key**: a new key replaces the old one here; add the new public key on the repository and **delete the
  old one there** (its fingerprint is shown).
- **Disconnect**: the key is deleted here; delete the deploy key on the repository too. The sessions that worked on
  it stay in History.

## Troubleshooting

- « the key is not on the repository yet »: the public key was not added (or not saved) as a deploy key.
- Pushing fails while Check works: « Allow write access » was not ticked.
- `https://` addresses are refused: deploy keys work over SSH; use the `git@…` address.
- A deploy key can be used by one repository only on GitHub: each repository needs its own (that is the point).
