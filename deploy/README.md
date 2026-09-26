# Wizard configuration

`./deploy.sh` is a generic engine: it has no idea what Frappe, MariaDB or Traefik are. Everything
it asks and everything it produces comes from the JSON files in this directory, so changing the
paths a stack can take means editing JSON only.

```
deploy/
├── wizard.json          # global settings: compose layers, stack naming, env files
└── steps/*.json         # the questions, asked in file-name order (10-…, 20-…)
```

Run `./deploy.sh --check` after editing (it validates everything below and reports file and
location), and `./deploy.sh --list` to see the resulting tree of steps, options and compose
files. `DEPLOY_CONFIG_DIR=other/dir ./deploy.sh` runs the engine on another config.

## How a stack is built

1. The steps are asked in order. A step or option whose `when` does not hold is skipped.
2. Each chosen option contributes compose files (grouped by **layer**), environment variables,
   files to copy from templates, and notes. Each text answer can fill an environment variable.
3. The engine writes the variables to the stack env file and runs:
   ```
   docker compose --project-directory . --project-name <project> \
     --env-file .env --env-file <stack env file> \
     -f <every compose file, layer by layer> config > <output>
   ```
   Later env files win, so the stack's answers override `.env`.
4. The answers (never the secrets) are saved so the stack can be reopened from the menu or
   replayed with `./deploy.sh --answers <file>`.

## `wizard.json`

| Key | Meaning |
|---|---|
| `title`, `subtitle` | Header of the interactive screens. |
| `layers` | **Merge order** of compose files. Options put their files into these layers; the engine passes layer 1's files first, then layer 2's, and so on (within a layer: step order, then option order). Later files win on conflicting keys. |
| `env_files` | Env files passed to `docker compose config` before the stack env file (e.g. `.env`). Missing ones are skipped. A variable already set here becomes the **default** of any step that writes it, so the wizard never silently overrides `.env`. |
| `files` | `[{"from", "to"}]` copied from a template when `to` is missing, for every stack (e.g. `example.env` → `.env`). |
| `stack.project` *(required)* | `docker compose --project-name`. |
| `stack.output` *(required)* | Rendered compose file. |
| `stack.env_file` | Where the answers' variables are written (mode 600 when it holds a secret). |
| `stack.answers` | Where the answers are saved. Its placeholders become `*` to find the existing stacks for the "open" menu. |
| `notes` | Lines shown after every render. |

The `stack` values may use placeholders (below). They are also placeholders themselves:
`{project}`, `{output}`, `{env_file}`, `{answers}` work in options' notes, files and env values.

## Steps (`steps/*.json`)

A file holds one step object or an array of them. Common keys:

| Key | Meaning |
|---|---|
| `id` *(required)* | `[a-z][a-z0-9_-]*`, unique. Used by `when`, placeholders, `--set id=value` and the answers file. |
| `type` *(required)* | `choose` (one option), `multi` (several), `input` (text), `secret` (masked text, never saved in the answers file). |
| `title` | Short name used in the summary. |
| `question` | Prompt. One of `title`/`question` is required. |
| `help` | Dimmed line under the header. |
| `when` | Condition, see below. |
| `default` | `choose`: an option id. `multi`: array of option ids. `input`/`secret`: text (placeholders allowed). |

`choose` / `multi` only:

| Key | Meaning |
|---|---|
| `options` *(required)* | Array of options (below). A `choose` step with a single visible option answers itself; a step with no visible option is skipped. |
| `min` | `multi`: minimum number of options to pick (default 0). |

`input` / `secret` only:

| Key | Meaning |
|---|---|
| `env` | Variable the answer is written to. |
| `pattern` | Bash extended regex the answer must match (`^.+$` = required). |
| `error` | Message shown when `pattern` does not match. |

### Options

| Key | Meaning |
|---|---|
| `id` *(required)* | `[a-z0-9][a-z0-9_-]*`, unique within the step. |
| `label` *(required)*, `description` | Menu text. |
| `when` | Condition, see below. |
| `compose` | `{"<layer>": ["file.yaml", ...]}`. Layers must be listed in `wizard.json`. |
| `env` | `{"VAR": "value"}` written to the stack env file. A later step writing the same variable wins. |
| `files` | `[{"from": "template", "to": "target"}]` copied when `target` is missing (asked, or `--yes`). Use this for per-deployment files a compose file needs. |
| `notes` | Lines shown after the render. |

## Conditions (`when`)

```json
"when": { "environment": ["prod"], "database": ["mariadb", "postgres"] }
```

Every listed step must be an **earlier** step. All keys must hold (AND); within a key, any value
may match (OR). A value starting with `!` excludes: `{"environment": ["!prod"]}` holds for every
environment except `prod`. For a `multi` step, a value matches when that option is among the
chosen ones. A skipped step has no answer, so positive conditions on it do not hold.

## Placeholders

`{name}` in any string is replaced by the answer of step `name` (a `multi` answer becomes its
space-separated option ids) or by a `stack` value (`{output}`, …). Unknown names are reported by
`--check`, so `{…}` with a lowercase name is always a placeholder. `$VAR` / `${VAR}` are left
alone for Docker Compose and the shell.

## JSON rules

Standard JSON parsed with `awk` (no `jq` needed), with a few limits reported as errors: object keys
may not contain dots or whitespace, strings are single-line (use arrays of lines for notes),
`\u` escapes are ASCII only (write other characters literally), and env values may not contain
single quotes.

## Example: adding a new database engine

```json
{
  "id": "mysql",
  "label": "MySQL 8",
  "description": "Community MySQL instead of MariaDB",
  "when": { "environment": ["prod"] },
  "compose": { "database": ["templates/docker/compose.mysql.yml"] },
  "notes": ["bench new-site needs --mariadb-user-host-login-scope=%"]
}
```

Add it to the `options` of the `database` step, create the compose fragment, run
`./deploy.sh --check`. No bash changes.
