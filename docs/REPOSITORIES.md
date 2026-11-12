# Connected repositories and their keys

Agent Manager GD launches agents on repositories **you** create (GitHub, Azure DevOps, or another SSH git host).
Each connected repository gets its own SSH key. What that key opens depends on the host, and the Repos page says it
on every line:

- **GitHub**: a **deploy key**, which opens that repository only.
- **Azure DevOps**: there is no key per repository. The key goes on your profile and **opens everything your
  account reaches there**. To keep agents to chosen repositories, add it to an account made for them.
- **Another host**: an ed25519 key; what it opens is that host's rule.

## The page

**⎇ Repos** opens on four tiles (keys that work, repositories that need a hand, sessions running, hosts), then
shows one repository per line, each column a small drawing: its host as a chip, its key's state with a bar that
empties in ten minutes (the age at which the page checks it again), what the key opens, the folder (yours or Agent
Manager's copy, its branch, commits not pushed, files changed), a dot per open session, and the sessions started on
it day by day over fourteen days. Rest the pointer on any of them for the words. The repositories that need a hand come first, unfolded. A click
on a name or its arrow unfolds the rest: the public key, where to add it, Check, Rotate the key, Disconnect, the
folder, and a map of its branches drawn like a metro's (the base branch at the top, each branch with commits, a
worktree or an open session running under it, with its sessions as dots). Opening the page reads the folders again and checks again the keys checked more than ten minutes ago;
**Check all** does it at once. Nothing is checked while the page is closed.

## Connect a repository

1. Create the repository on GitHub (or elsewhere).
2. In Agent Manager: **⎇ Repos → Add a repository**: its SSH address (`git@github.com:owner/repo.git`) and, if you
   want, the local folder where it is (or should be) cloned. Without a folder, it is cloned on first use into
   Agent Manager's data folder (`~/.local/share/agent-manager-gd/repos/<name>`).
3. Agent Manager makes an ed25519 key for that repository and shows its **public** key. **Copy the public key**, then
   **Open GitHub's Deploy keys page** (or *Settings → Deploy keys → Add deploy key* on the repository): paste it, give it
   a title, tick **Allow write access** (agents push their branch with it), save.
4. Back in Agent Manager: **Check**. The line then says the key works, and when that was checked.

## Azure DevOps

1. On the repository's page: **Clone › SSH**, and copy the address
   (`git@ssh.dev.azure.com:v3/organization/project/repository`). A web address pasted in the form is answered with
   this SSH form.
2. In Agent Manager: **⎇ Repos → + Connect a repository**. Agent Manager makes an **RSA** key: the only kind Azure
   DevOps accepts.
3. **Copy the public key**, **Open Azure DevOps**, then *User settings* (the icon beside your picture) → *SSH public
   keys* → *New Key*: paste it, save.
4. Back in Agent Manager: **Check**.

Azure DevOps keys expire, and it warns you by e-mail seven days before: **Rotate the key** then, and add the new one.
SSH must be allowed for the organization. This path was built from Microsoft's documentation and its server's own
answer about the keys it accepts; it has not been tried against a real Azure DevOps repository yet.

## Work on it

**New session** → *Repository*: pick it. The session works in the repository's folder (a git worktree per session if
you tick « In its own git branch »), and every git command in that session uses the repository's key only
(`GIT_SSH_COMMAND` with `IdentitiesOnly=yes`), never your personal SSH keys. The card shows « ⎇ <repository> ».

## Where things are, and what never happens

| What | Where |
|---|---|
| Private key | `~/.local/share/agent-manager-gd/keys/<id>/id_ed25519`, or `id_rsa` for Azure DevOps (mode 0600, readable by you only) |
| Public key | same folder, the same name with `.pub` (safe to share) |
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
- `https://` addresses are refused: the keys work over SSH. The refusal gives the `git@…` address where it can be worked out, and the form fills it in.
- Azure DevOps, « the key is not on your Azure DevOps profile yet »: add it under *User settings → SSH public keys*, and see that SSH is allowed for the organization.
- A deploy key can be used by one repository only on GitHub: each repository needs its own (that is the point).
