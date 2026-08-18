# CLAUDE.md

A Neovim plugin that lints WordPress commit messages, per the [WordPress Core Handbook commit message guidelines](https://make.wordpress.org/core/handbook/best-practices/commit-messages/). It attaches to `COMMIT_EDITMSG` and `svn-commit.tmp` buffers.

## Conventions

- Linting is hand-rolled pattern matching in `linter.lua`. There is no Treesitter grammar, no `queries/`, and no build step — do not add one without discussing it first.
- All Lua is formatted with `stylua`. There is no `stylua.toml` in the repo, so match the surrounding formatting by hand.
- Plugin config lives in `init.lua`'s `default_config`, not a separate `config.lua`.

## Target Users

WordPress core committers who:

- Use Neovim as their primary editor
- Commit via `svn commit` (which opens `$SVN_EDITOR`)
- Need assistance following the strict WordPress commit message format
- Want real-time feedback while writing commit messages

## WordPress Commit Message Format

The plugin validates against this strict format:

```
Component: Brief summary.

Longer description with more details, such as a `new_hook` being introduced with the context of a `$post` and a `$screen`.

More paragraphs can be added as needed.

Example usage:

{{{
// Multi-line code snippet.
$add_filter( 'some_new_filter', 'some_filter_callback' );
}}}

Developed in: https://github.com/WordPress/wordpress-develop/pull/6395
Discussed in: https://wordpress.slack.com/archives/C18723MQ8/p1782986746738579

Follow-up to r27195, r41062.

Reviewed by a-fellow-committer, maybe-multiple.
Merges r26851 to the x.x branch.

Props person, another.
Fixes #30000. See #20202, #105.
```

## Known Issues

### API Request Failures on Bulk Validation

**Issue:** When a commit message is loaded with multiple references (tickets, changesets, usernames), concurrent API requests can fail due to rate limiting or network issues, causing valid references to be incorrectly cached as invalid.

**Symptoms:**

- Valid tickets showing ✗ instead of ✓
- Valid WordPress.org usernames marked as invalid
- Valid changesets not resolving properly

**Workaround:**

- Edit the commit message (add/remove a character) to trigger re-validation
- Or restart Neovim to clear the cache

**Root Cause:** The current implementation makes multiple concurrent HTTP requests when validating complex commit messages. Some requests may fail due to:

- Network timeouts (10s limit)
- API rate limiting
- Concurrent request limits
- Network instability

**Potential Solutions:**

- Implement exponential backoff retry logic for failed requests
- Add sequential request queuing instead of concurrent requests
- Distinguish between network failures and actual invalid references
- Add manual cache invalidation command
- Implement request batching where possible
