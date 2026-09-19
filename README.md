# Semantic Clause Break

This is a CLI application to reformat prose in markdown files such that each independent clause is given its own line in the markdown source.
The intent is to make diffs easier to parse for humans.

- Each independent clause is given its own line.
- Applies to paragraphs, lists (numbered and bulleted), and block quotes.
- Does _not_ apply to headings, tables, or source code.

The files to process are provided as CLI arguments.
The default output reports the number of errors in each file, exiting 0 only if there are no errors in any file.

The `--fix` option can be passed to the CLI to apply the changes to the provided files.
This exits 1 if changes were made and 0 if no changes were needed (i.e. there were no existing errors in any files).

## Examples

Given this file:

````markdown
# Release notes. Read carefully.

This release fixes a crash on startup. It also improves error messages.

> The migration is required before upgrading. It only takes a minute.

- Restart the service after upgrading. It will not pick up the new config otherwise.

| Version | Notes                          |
| ------- | ------------------------------ |
| 2.0     | Requires a restart. See below. |

```
# not touched. still one line.
```
````

`semantic-clause-break notes.md` reports 3 errors.
The paragraph, the block quote, and the list item each have two clauses sharing one line.
The heading, the table, and the code block are left alone even though they also contain sentence-like text.

Running `semantic-clause-break --fix notes.md` rewrites the file to:

````markdown
# Release notes. Read carefully.

This release fixes a crash on startup.
It also improves error messages.

> The migration is required before upgrading.
> It only takes a minute.

- Restart the service after upgrading.
  It will not pick up the new config otherwise.

| Version | Notes                          |
| ------- | ------------------------------ |
| 2.0     | Requires a restart. See below. |

```
# not touched. still one line.
```
````

Only the lines that needed a break were touched.
Block quotes keep their `>` marker on the new line, and list items are continued with spaces matching the marker's width rather than a new `-`.
