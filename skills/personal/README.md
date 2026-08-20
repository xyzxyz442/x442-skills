# personal

Skills tied to one person's own setup — a local model gateway, a private tool, a machine-specific
workflow. They are **not promoted**: the dev-loop link scripts skip this directory by default, so
nothing here installs into `~/.agents/skills/` unless you ask for it.

Install them with the opt-in flag:

```bash
scripts/link-claude-skills.sh --personal
```

Without `--personal` the scripts behave exactly as before, so a personal skill can never leak into
a teammate's environment by accident.

A skill belongs here rather than in [engineering](../engineering/README.md) when it depends on
something only you have — credentials, a running endpoint, a private host — such that another
person cloning this repo could not use it without setting that up first.

## Skills in this category

| Skill                      | Status         | Purpose                                                                                                                                                                                  |
| -------------------------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `register-delegate-agents` | `experimental` | Manage the `.agents/delegate.json` cascade — declare agents in an uncommittable layer, narrow per repo, set the primary. Chains before `setup-delegate-agent`.                           |
| `setup-delegate-agent`     | `experimental` | Install the dispatcher, adapters, consent gate and credential scanning, and render an `AGENTS.md` routing block from the agents a repo permits. Chains after `register-delegate-agents`. |
| `run-delegate-agent`       | `experimental` | The assess → ask → brief → dispatch → verify → report discipline over an installed setup. Chains after `setup-delegate-agent`.                                                           |

Full per-skill detail (prerequisites, verification harness, status meanings) lives in the
[skills catalog](../README.md).

## Authoring conventions

See [../README.md](../README.md) for the catalog's authoring section and [../../AGENTS.md](../../AGENTS.md)
for the full skill-authoring rules (frontmatter, naming, house rules). Folders stay
unprefixed; the `x442-` prefix lives in each skill's frontmatter `name`.
