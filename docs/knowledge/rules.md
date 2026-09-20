# Repo rules

Conventions that apply to every action in this repo. Read before adding or
changing an action.

## Every action folder has a README.md

Keep it as simple as possible. Two required parts, nothing more:

1. **Inputs** — a table of every input the action accepts: name, default, and a
   one-line description. Mark required inputs. Add an Outputs table in the same
   shape when the action has outputs.
2. **Usage** — copy-pasteable `uses:` snippets for the common cases. One per
   meaningful variation, not one per possible input combination.

Leave out rationale, design history, alternatives considered and exhaustive
prose. That belongs in `docs/superpowers/specs/`. The README answers "what can I
pass, and what does a working call look like", and stops there.

### Template

````markdown
# <action-name>

<One sentence: what it does.>

## Inputs

| Input | Default | Description |
|---|---|---|
| `foo` | *required* | What it is. |
| `bar` | `baz` | What it is. |

## Outputs

| Output | Description |
|---|---|
| `qux` | What it is. |

## Usage

```yaml
- uses: dbiagi/actions/<action-name>@v1
  with:
    foo: value
```
````

The root `README.md` stays an index: one line per action, linking to its folder.
Action detail does not get duplicated there.
