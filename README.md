# wp-commit

> ⚠️ **Use at your own risk**: This plugin is experimental and may show incorrect validation results for tickets, changesets, and usernames due to API reliability issues.

A Neovim plugin for linting WordPress commit messages according to the [WordPress Core Handbook commit message guidelines](https://make.wordpress.org/core/handbook/best-practices/commit-messages/).

## Features

- Real-time validation of WordPress commit message format
- Inline status indicators (✓/✗/?) for ticket references, changesets, and Props usernames
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
- A curl-compatible WordPress Trac cookie file for ticket and changeset validation

## Configuration

Ticket and changeset validation uses WordPress Trac and requires a cookie file. The plugin supports curl/Netscape cookie jars, Set-Cookie style files, and raw `NAME=VALUE; NAME2=VALUE2` cookie header files. Raw cookie header files are passed to `curl` through stdin so the cookie value does not appear in process arguments.

```sh
export WP_COMMIT_TRAC_COOKIE_FILE="$HOME/.config/wp-commit/trac-cookies.txt"
```

```lua
require("wp-commit").setup({
  trac = {
    cookie_file = vim.env.WP_COMMIT_TRAC_COOKIE_FILE,
  },
})
```

Keep the cookie file outside the repository, do not commit it, and restrict its permissions, for example with `chmod 600 ~/.config/wp-commit/trac-cookies.txt`. If the cookie is missing, unreadable, expired, unsupported, or Trac is unavailable, ticket and changeset references are shown as unchecked (`?`) instead of invalid (`✗`).

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

- API requests may fail when validating multiple references at once.
- Ticket and changeset auth, network, or parsing failures are shown as unchecked (`?`) instead of invalid (`✗`).
- Username validation may still show valid WordPress.org users as invalid (`✗`) if profile requests fail.
- Workaround: Edit the message to trigger re-validation.

**Always double-check references manually before committing important changes.**

## License

GPL 2 or later
