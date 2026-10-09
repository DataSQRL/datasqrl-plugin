# Contributing

Thanks for helping improve the DataSQRL plugin.

## Issues and pull requests

- **Report a problem** with an issue. Include your coding agent (Claude Code, Codex, Cursor or Copilot), the plugin version, and the output of `datasqrl-agent.sh --check-config`.
- **Propose a change** with a pull request against `main`. For a larger change, open an issue first.
- **Title the pull request** with a [Conventional Commits](https://www.conventionalcommits.org) prefix, such as `feat: add a status skill` or `fix: find the launcher on Windows`. CI checks it.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Test a change locally

Install the plugin from your clone:

```
/plugin marketplace add /absolute/path/to/datasqrl-plugin
/plugin install datasqrl@datasqrl
```

Edits to a `SKILL.md` take effect immediately. After editing a manifest, run `/plugin marketplace update datasqrl` and `/reload-plugins`.

Before you open a pull request, run the checks CI runs:

```bash
.github/check-plugin.sh
```

## Rules to keep in mind

- Keep files under `scripts/` as real, executable files. Plugin hosts copy the plugin on install, and a symlink arrives empty.
- Leave the `skills` key out of `.claude-plugin/plugin.json`. With it, Claude Code loads only the skills it lists.
- Put maintainer notes in this file, not in HTML comments in a skill. Agents read the comments as plain text.
- `datasqrl-agent.sh` runs the DataSQRL agent's Docker image. If your change makes it use a new option of that image, merge it only after the image with that option is published. Otherwise users get a launcher that calls an option their image does not have.

## License

By contributing, you agree that your contributions are licensed under the [Apache License, Version 2.0](LICENSE).
