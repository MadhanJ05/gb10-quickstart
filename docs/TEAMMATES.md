# Teammates: sharing one GB10

> **Status:** the owner's path (one Tailscale account, owner's laptop → box) is verified. The teammate steps below
> (tailnet invites, machine sharing, extra logins) are **not yet tested by us**; they follow Tailscale's and Ubuntu's
> documented features. Please open an issue if something differs.

A teammate needs two things: a **network path** to the box (Tailscale) and a **way to log in** (a Linux account
or SSH key).

## 1. Network path (Tailscale)

Every teammate installs the Tailscale app on their laptop. Then the box owner picks one option in the
[Tailscale admin console](https://login.tailscale.com/admin):

| Option | Where | What the teammate gets |
|---|---|---|
| **Share just this machine** (narrower) | Machines → `…` next to the box → **Share** | This one machine appears in their own tailnet. They see nothing else of yours. |
| **Invite them to your tailnet** | Users → **Invite users** | They join your tailnet and can see your other devices too (subject to your access rules). |

Then the teammate checks with `tailscale status` on their laptop, and connects with the box's `100.x.y.z` IP
(the owner gets it from `tailscale ip -4`). MagicDNS names can differ for shared machines, so the IP is the safe choice.

## 2. A way to log in

**Option A: their SSH key on your account (quickest).** The teammate creates a key on their laptop, if they don't
have one, and sends you the **public** half (the `.pub` file; never the private one):

```bash
# on the teammate's laptop
ssh-keygen -t ed25519            # accept the defaults
cat ~/.ssh/id_ed25519.pub         # send this one line to the box owner
```

```bash
# on the box, as the owner
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys       # paste the line at the end, save
chmod 600 ~/.ssh/authorized_keys
```

They then `ssh <owner-user>@100.x.y.z`. **They act as you:** they can read your files, `.env` files, and anything
you're logged in to (GitHub CLI, Tailscale, cloud CLIs). Only do this with people you trust that much.

**Option B: separate Linux users (better isolation).** The owner runs `sudo adduser alice` and puts Alice's public key
in `/home/alice/.ssh/authorized_keys` (owned by alice, mode 600). Each user then clones this kit and runs
`20_alchemi_env.sh` in their own home. uv's download cache is per user, so each user downloads the packages again.

**Option C: a shared password.** This works only if SSH password login is allowed on the box. It's the least
safe option; prefer A or B.

## 3. Sharing one GPU

- `nvidia-smi` shows who's running what (the memory column says `[N/A]` on GB10 because memory is unified; look at the
  process list).
- The 121 GiB of memory is shared by CPU and GPU, so one big job can squeeze everyone. Agree on who runs long jobs.
- Run long jobs in `tmux` so they survive a dropped SSH connection: `tmux new -s myrun`, detach with `Ctrl-b d`,
  reattach with `tmux attach -t myrun`.
- Throughput drops when two MD jobs share the GPU. `30_smoke_test.sh` warns if you're under half our reference speed.

## 4. Copy and paste from a Mac over SSH

Claude Code (and tmux/vim with mouse mode) capture mouse drags, so a normal drag doesn't select text.

| Terminal | How to select anyway | Our status |
|---|---|---|
| macOS Terminal.app | hold **Fn** while dragging, or toggle mouse reporting with **Cmd+R** (View → Allow Mouse Reporting) | untested |
| iTerm2 | hold **Option** while dragging | standard iTerm2 behavior, untested by us. Option+drag did **not** work in what was likely Terminal.app. |

Then copy with **Cmd+C**. In a terminal, **Ctrl+C means "interrupt"**, not copy.

## 5. Secrets on a shared box

Save API keys without them landing in chat or shell history:

```bash
nano ~/my-project/.env          # add a line: NAME=value
chmod 600 ~/my-project/.env
grep -qxF '.env' ~/my-project/.gitignore 2>/dev/null || echo '.env' >> ~/my-project/.gitignore
```

Anyone who logs in as your user (Option A above) can still read it.
