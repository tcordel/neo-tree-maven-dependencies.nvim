# Maven dependency extension for [Neotree](https://github.com/nvim-neo-tree/neo-tree.nvim)

## Purpose

[nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls) is perfect to code and use [eclipse-jdtls](https://github.com/eclipse-jdtls/eclipse.jdt.ls) LSP.
We can easily access to .class decompiled content threw fzf.

But in some cases, i needed to scrub into a jar content to get more details about how the library is done (i.e : spring properties, spi ...) or which classes does the library provides in surrounding packages.

![Neotree maven example](./images/neotree-maven-example.png)

## Installation

> **_NOTE_** Actually, this plugin is working only on linux

Required dependencies:
* `mvn`
* `unzip`

> Using Lazy:
```lua
return {
	"nvim-neo-tree/neo-tree.nvim",
	-- branch = "v3.x",
	dependencies = {
		"nvim-lua/plenary.nvim",
		"tcordel/neo-tree-maven-dependencies.nvim",
	},
	opts = function(_, opts)
		table.insert(opts.sources, "maven")
		opts.maven = {
			window = {
				mappings = {
					["I"] = "invalidate",
				},
			},
			group_dirs_and_files = true, -- when true, empty folders and files will be grouped together
			group_empty_dirs = true, -- when true, empty directories will be grouped together
			renderers = {
				directory = {
					{ "indent" },
					{ "icon" },
					{ "name" },
				},
				file = {
					{ "indent" },
					{ "icon" },
					{ "name" },
				},
			},
		}
	end,
}
```

## Usage

`Neotree maven`: will open the dependency list. A dependency analysis will be processed on the first opening

To invalidate, simply push `I` in the list
