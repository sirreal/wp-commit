# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Neovim plugin for linting WordPress commit messages according to the [official WordPress commit message guidelines](https://make.wordpress.org/core/handbook/best-practices/commit-messages/). The plugin provides real-time validation and feedback when editing commit messages in Neovim, specifically designed for WordPress core committers using `svn commit` workflows.

## Architecture

### Core Components

- **`lua/wp-commit-msg/`** - Main plugin logic

  - `init.lua` - Plugin entry point and setup
  - `linter.lua` - Core linting engine with WordPress-specific rules
  - `config.lua` - Configuration management and defaults
  - `parser.lua` - Treesitter integration and AST utilities
  - `trac.lua` - WordPress Trac integration for tickets/changesets
  - `profiles.lua` - WordPress.org profile validation

- **`queries/`** - Treesitter queries for syntax highlighting and parsing

- **`plugin/wp-commit-msg.vim`** - Vim plugin integration and autocommands

### Key Features to Implement

1. **Real-time Linting Rules:**

   - Summary line validation (50-70 character limit, component prefix format)
   - Proper capitalization and punctuation
   - Code/hook backtick validation
   - Props section formatting with WordPress.org profile validation
   - Ticket reference validation (#123 format) with existence checking
   - Changeset reference validation ([123] format) with existence checking
   - Required blank lines between sections
   - Follow-up/Reviewed by/Merges section validation

2. **API Integration Features:**

   - Show inline hints with ticket/changeset titles on hover or as virtual text
   - Cache validation results to avoid repeated API calls
   - Graceful degradation when offline or API unavailable

3. **Integration:**

   - Automatic activation for commit message buffers (COMMIT_EDITMSG, svn-commit.tmp)
   - Works with git-svn and native svn workflows
   - Configurable via Neovim's standard config system

4. **User Experience:**
   - Inline diagnostics showing errors/warnings
   - Syntax highlighting for different message sections
   - Virtual text showing ticket/changeset titles (e.g., "Fixes #12345. → Fix memory leak in widget handling")
   - Optional template insertion for new commit messages
   - Hover information for ticket/changeset references

## Parsing Strategy

The plugin uses **Treesitter** with a custom `tree-sitter-wordpress-commit` grammar for parsing WordPress commit messages. This provides:

- Robust syntax highlighting via treesitter queries
- AST-based linting for accurate validation
- Incremental parsing for performance
- Better error recovery for malformed messages

Key elements parsed: component prefixes, ticket references (#123), changeset references ([123]), WordPress.org usernames in props, code spans (`hooks`), section keywords (Props, Fixes, etc.), and proper section boundaries.

## WordPress Commit Message Format

The plugin validates against this strict format:

```
Component: Brief summary.

Longer description with more details, such as a `new_hook` being introduced with the context of a `$post` and a `$screen`.

More paragraphs can be added as needed.

Follow-up to [27195], [41062].

Reviewed by committer-name.
Merges [26851] to the x.x branch.

Props person, another.
Fixes #30000. See #20202, #105.
```

## Development Commands

- **Setup:** Install treesitter grammar: `npm install` (for building tree-sitter-wordpress-commit)
- **Test:** Manual testing with sample commit messages in Neovim
- **Lint:** Standard Lua linting via `luacheck` if available
- **Format:** All Lua code is formatted with `stylua` - ensure new code follows the same formatting standards

## File Structure

```
├── lua/
│   └── wp-commit-msg/
│       ├── init.lua          # Main plugin entry
│       ├── linter.lua        # Core linting logic
│       ├── config.lua        # Configuration
│       ├── parser.lua        # Treesitter integration
│       ├── trac.lua          # Trac API integration for tickets/changesets
│       └── profiles.lua      # WordPress.org profile validation
├── queries/
│   ├── highlights.scm        # Syntax highlighting queries
│   └── locals.scm           # Additional treesitter queries
├── plugin/
│   └── wp-commit-msg.vim     # Vim integration
├── doc/
│   └── wp-commit-msg.txt     # Neovim help documentation
└── README.md                 # Installation and usage
```

## Target Users

WordPress core committers who:

- Use Neovim as their primary editor
- Commit via `svn commit` (which opens `$SVN_EDITOR`)
- Need assistance following the strict WordPress commit message format
- Want real-time feedback while writing commit messages

## Integration Notes

- The plugin should activate automatically when editing commit message files
- Must handle both git commit messages (COMMIT_EDITMSG) and svn commit messages (svn-commit.tmp)
- Should be lightweight and not interfere with existing Neovim configurations
- Configuration should follow Neovim plugin standards (setup function, etc.)

## WordPress Integration

### API Endpoints

- **Tickets:** `https://core.trac.wordpress.org/ticket/123?format=csv` (returns CSV with id, summary, etc.)
- **Changesets:** `https://core.trac.wordpress.org/changeset/60487` (parse HTML `#overview` dl element for commit message)
- **User Profiles:** `https://profiles.wordpress.org/username` (HEAD request, check 2xx vs non-2xx status)

### Validation Features

- Check if ticket/changeset numbers exist
- Validate WordPress.org usernames in props section
- Extract and display titles/names as virtual text or hover info
- Cache results to minimize API calls
- Handle rate limiting gracefully
- Show appropriate error messages for invalid references

### Examples

```
Fixes #12345.           → "Fix memory leak in widget handling"
Follow-up to [60487].   → "Component: Brief summary of changeset"
See #20202.             → "Enhancement: Add new filter hook"
Props jonsurrell, dmsnell. → "✓ jonsurrell ✓ dmsnell" (or ✗ for invalid users)
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
