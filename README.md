# Semantic Clause Break

This is a CLI application that ensure that prose in markdown files is split at independent clauses.
The intent is to make diffs easier to parse for humans.

- Each independent clause is given its own line.
- Applies for all prose including paragraphs, lists, and block quotes.
- Does _not_ apply to headings, tables, or source code.

The files to process are provided as CLI arguments.
The default output reports the number of errors in each file, exiting 0 only if there are no errors in any file.

The `--fix` option can be passed to the CLI to apply the changes to the provided files.
This exits 1 if changes were made and 0 if no changes were needed (i.e. there were no existing errors in any files).
