# git-conflict.nvim

https://user-images.githubusercontent.com/22454918/159362564-a66d8c23-f7dc-4d1d-8e88-c5c73a49047e.mov

A plugin to visualise and resolve git conflicts in neovim, forked from
[akinsho/git-conflict.nvim](https://github.com/akinsho/git-conflict.nvim).

Conflicts are found by their markers in the buffer rather than by asking git which files are
unmerged, so they are highlighted wherever they turn up: whatever your working directory, inside
worktrees and submodules, and in files git no longer reports as conflicted. The flip side is that
a file merely containing a full set of markers — documentation about merge conflicts, a test
fixture — is treated as conflicted too.

The plugin claims no keys of its own. Everything it does is a command, and [`mappings`](#mappings)
binds whichever keys you choose to them, only while a buffer has conflicts.

## Requirements

- `git`
- `nvim 0.10+`

## Installation

```lua
-- lazy.nvim
{ 'KaySum/git-conflict.nvim', config = true }

-- packer.nvim
use {'KaySum/git-conflict.nvim', config = function()
  require('git-conflict').setup()
end}
```

There are no tags, so leave your package manager's `version` / `tag` field out and track `main`,
or pin a commit if you want to control when you pick up changes.

## Configuration

```lua
{
  mappings = {}, -- list of { lhs, rhs, ... }; empty by default, see Mappings below
  default_commands = true, -- disable commands created by this plugin
  disable_diagnostics = false, -- This will disable the diagnostics in a buffer whilst it is conflicted
  list_opener = 'copen', -- command or function to open the conflicts list
  highlights = { -- They must have background color, otherwise the default color will be used
    incoming = 'DiffAdd',
    current = 'DiffText',
  }
}
```

## Commands

- `GitConflictChooseOurs` — Select the current changes.
- `GitConflictChooseTheirs` — Select the incoming changes.
- `GitConflictChooseBase` — Select the common ancestor, shown by `diff3`/`zdiff3`.
- `GitConflictChooseBoth` — Select both changes.
- `GitConflictChooseNone` — Select none of the changes.
- `GitConflictNextConflict` — Move to the next conflict.
- `GitConflictPrevConflict` — Move to the previous conflict.
- `GitConflictListQf` — Send the project's conflicts to the quickfix list.
- `GitConflictRefresh` — Re-scan the current buffer for conflict markers.

The `Choose` commands also work over a visual selection, where they resolve every conflict inside
it at once.

### Listing conflicts

You can list conflicts in the quick fix list using the `GitConflictListQf` command

<img width="475" alt="Screen Shot 2022-03-27 at 12 03 43" src="https://user-images.githubusercontent.com/22454918/160278511-705a0361-a387-4fc1-8b20-bd799bf85b82.png">

quickfix displayed using [nvim-pqf](https://github.com/yorickpeterse/nvim-pqf)

## Autocommands

When a conflict is detected by this plugin a `User` autocommand is fired
called `GitConflictDetected`. When this is resolved another command is
fired called `GitConflictResolved`.

Either of these can be used to run logic whilst dealing with conflicts
e.g.

Both carry the buffer they describe as `data.bufnr`.

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'GitConflictDetected',
  callback = function(args)
    vim.notify('Conflict detected in ' .. vim.api.nvim_buf_get_name(args.data.bufnr))
  end,
})
```

To bind keys only while a buffer has conflicts you do not need an autocommand —
use [`mappings`](#mappings).

## Mappings

This plugin claims **no keys of its own**. List the ones you want in `mappings`, written like a
[lazy.nvim](https://github.com/folke/lazy.nvim) `keys` entry — `{ lhs, rhs, ... }`. They are
applied buffer-locally while a buffer has conflicts and removed once it no longer does, so the
keys stay free everywhere else.

```lua
require('git-conflict').setup {
  mappings = {
    { 'co', '<cmd>GitConflictChooseOurs<cr>', mode = { 'n', 'x' }, desc = 'Choose Ours' },
    { 'ct', '<cmd>GitConflictChooseTheirs<cr>', mode = { 'n', 'x' }, desc = 'Choose Theirs' },
    { 'cb', '<cmd>GitConflictChooseBoth<cr>', mode = { 'n', 'x' }, desc = 'Choose Both' },
    { 'ca', '<cmd>GitConflictChooseBase<cr>', mode = { 'n', 'x' }, desc = 'Choose Base' },
    { 'c0', '<cmd>GitConflictChooseNone<cr>', mode = { 'n', 'x' }, desc = 'Choose None' },
    { ']x', '<cmd>GitConflictNextConflict<cr>', desc = 'Next Conflict' },
    { '[x', '<cmd>GitConflictPrevConflict<cr>', desc = 'Prev Conflict' },
  },
}
```

`rhs` is anything `vim.keymap.set` accepts — a command string or a Lua function. `mode` defaults
to normal; any other field (`desc`, `expr`, `nowait`, …) is passed straight through, and `silent`
defaults to `true`. An entry missing its `lhs` or `rhs` is reported once, at startup, and skipped.

Bind the choose commands in visual mode as well to resolve every conflict inside a selection at
once.

Every action is also a `<Plug>` mapping, if you would rather bind it yourself:

```lua
vim.keymap.set({ 'n', 'x' }, 'co', '<Plug>(git-conflict-ours)')
vim.keymap.set('n', ']x', '<Plug>(git-conflict-next-conflict)')
```

`<Plug>(git-conflict-ours)`, `-theirs`, `-both`, `-base`, `-none`, `-next-conflict` and
`-prev-conflict`. Unlike `mappings`, these are global — binding them yourself means they apply in
every buffer, not just conflicted ones.

The [commands](#commands) work anywhere, with no mapping at all.

## API

This plugin exposes an API to extract some of the data it collects for other
purposes.

<details><summary>conflict_count({bufnr})</summary>

```vimdoc
    Returns the amount of conflicts in a given buffer.
    

    Parameters:
	{bufnr} (number) Specify the buffer for which you want to know the
	                 amount of conflicts (default: current buffer).

    Return:
	number: The amount of conflicts.
```
</details>
