# wp-commit

> ⚠️ **Use at your own risk**: This plugin is experimental and may show incorrect validation results for tickets, changesets, and usernames due to API reliability issues.

A Neovim plugin for linting WordPress commit messages according to the [WordPress Core Handbook commit message guidelines](https://make.wordpress.org/core/handbook/best-practices/commit-messages/).

## Features

- Real-time validation of WordPress commit message format
- Inline status indicators (✓/✗) for ticket references, changesets, and Props usernames
- Virtual text showing ticket titles and changeset summaries
- Automatic activation for commit message files

## Installation

Add to your Neovim configuration:

```lua
-- Using lazy.nvim
{
  "path/to/wp-commit",
  config = function()
    require("wp-commit").setup()
  end,
}

-- Or in init.lua
require("wp-commit").setup()
```

## Requirements

- Neovim 0.7+
- `curl` command available
- Internet connection for API validation

## Format

Validates the official WordPress commit format:

```
Component: Brief summary.

Longer description if needed.

Follow-up to [12345].
Props username1, username2.
Fixes #67890. See #12345.
```

## Known Issues

- API requests may fail when validating multiple references at once
- Valid tickets/changesets/usernames may show as invalid (✗) incorrectly
- Workaround: Edit the message to trigger re-validation

**Always double-check references manually before committing important changes.**

## License

GPL 2 or later
