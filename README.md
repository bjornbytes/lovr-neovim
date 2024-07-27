Neovim for LÖVR
===

This is a LÖVR client for the neovim text editor.  It lets you connect to an instance of neovim
(potentially on a different machine), send keypresses to it, and render the result in LÖVR.  The
library is minimal in nature and is designed to be embedded in a larger development environment.

Note: this requires 2 native LÖVR plugins, [`lua-mp`](https://github.com/bjornbytes/lua-mp/tree/lovr) and
[`luv`](https://github.com/bjornbytes/luv/tree/lovr).

![com oculus vrshell-20250116-174734](https://github.com/user-attachments/assets/6d4d8d20-7bfb-4dbf-a47f-b842ee038599)

Features
---

- Can spawn multiple neovim connections.
- Behaves just like neovim would, all your config/theme/plugins work.
- Can connect to PC neovim from standalone Android headsets.
- Can send virtual keyboard/mouse events (or just forward the ones from `lovr.keypressed` etc.).
- Tells you when the editor has changed, so you can cache the rendering to a Texture or Layer and
  only redraw when needed.


Not yet implemented:

- Loading the system font set by vimrc.  Currently you have to provide your own font.
- Bold/underline/strikethrough/emoji text effects aren't supported.

How It Works
---

Neovim has a client/server design where a single instance of the editor can have multiple clients
connected to it, communicating using the MessagePack RPC protocol.  This library acts as a client.
The server sends us a grid of characters which are rendered to a LÖVR `Pass` object.  We can also
send keyboard events back to the server, and it will update the grid and send back the result.

Example
---

```lua
local editor = require 'neovim'

function lovr.load()
  editor:init({
    width = 800,
    height = 600,
    font = lovr.graphics.newFont('font.ttf'),
    fontSize = 18
  })
end

function lovr.update(dt)
  editor:update()
end

function lovr.draw(pass)
  pass:push()
  pass:translate(0, 1.7, -1)
  pass:scale(1 / 500) -- 500 pixels per meter
  pass:translate(-editor.width * .5, editor.height * .5, 0)
  editor:draw(pass)
  pass:pop()
end

function lovr.keypressed(key)
  editor:keypressed(key)
end

function lovr.keyreleased(key)
  editor:keyreleased(key)
end

function lovr.textinput(text)
  editor:textinput(text)
end
```

See `main.lua` for a full example.  You can pass a server address as the first command line
argument. Controller inputs will be converted to mouse inputs (trigger is click, thumbstick is
scroll).  It also caches the rendering to a `Layer` object, only redrawing when the editor contents
change.

Usage
---

lovr-neovim can be used in two ways:

- **Embedded**.  The library will start a new headless neovim process, and communicate with it over
  stdin and stdout.  Requires neovim to be installed.  This is the default if no IP is given.  
- **Remote**.  The library will connect to a neovim server over the network using its IP address.

For embedded, make sure neovim is installed.  `neovim:init` will try to spawn the `nvim` executable.
If you don't have a `nvim` executable on your PATH, set the `exe` config option to the path to
neovim.  The `cwd` option can also be set to change the editor's working directory.  Example:

```lua
neovim:init({
  exe = '/usr/bin/nvim',
  cwd = '/home/user'
})
```

For remote, first launch neovim with `--listen 0.0.0.0:1337` to have it listen on a TCP socket (here
I chose port 1337 but it can be anything).  You can run `:echo serverlist()` from neovim to see the
server address.  Then when initializing lovr-neovim, set the `address` to the server address:

```lua
neovim:init({
  address = '127.0.0.1:1337'
})

-- or this
neovim:init({
  address = '127.0.0.1',
  port = 1337
})
```

API
---

```lua
neovim:init(options)
editor = neovim.new(options)
```

Create a new editor.  You can call `init` on the library if you only plan on using a single editor,
or you can use `.new` to create multiple different editors.

`options` can be a table with the following:

name            | description
:---------------|:-----------
`address`       | The IP of the server to connect to.  Can also contain both the IP and port separated by a colon.  If this is nil, a new headless neovim process will be spawned.
`port`          | The port of the server to connect to, when connecting by IP.
`exe`           | The neovim executable to spawn.  Default: `nvim`.
`cwd`           | The working directory to use for the neovim process.  Default: `lovr.filesystem.getWorkingDirectory()`.
`width`         | The width of the editor, in pixels.  Default: 800.
`height`        | The height of the editor, in pixels.  Default: 600.
`font`          | The font to use.  Should be monospace.
`fontSize`      | The font size, in pixels.  Default: 16.
`onquit`        | Called when the editor quits.  Default: `lovr.event.quit`.
`onfontchanged` | Called when the neovim font setting is changed.
`onerror`       | Called when there is an error.  Default: `error`.
`capsescape`    | Whether `keypressed` should map `capslock` to `escape`.

```lua
dirty = neovim:update()
```

This should be called every frame from `lovr.update`.  It polls the connection for messages and
updates the state of the editor.  It returns `dirty`, indicating if the editor needs to be redrawn.

```lua
neovim:draw(pass)
```

Draws the editor to `pass`.  The upper left corner of the editor is at `(0,0)` and the units are in
pixels.  Currently it doesn't support transform information, so use the pass transform stack to
transform it as needed.

```lua
neovim:quit()
```

Shuts down the editor, closing the connection or killing the child process.

```lua
neovim:keypressed(key)
```

Send a key press to the editor.  This works with modifier keys, so sending a keypress for `lctrl`
and a textinput for `r` will send `<C-r>` to neovim.

```lua
neovim:keyreleased(key)
```

This is currently only used to track modifier key state.

```lua
neovim:textinput(text)
```

Send a text input event to the editor.

```lua
neovim:mousepressed(button, row, col)
```

Sends a mouse press event to the editor.

```lua
neovim:mousereleased(button, row, col)
```

Sends a mouse release event to the editor.

```lua
neovim:mousemoved(row, col)
```

Sends a mouse move event to the editor.

```lua
neovim:wheelmoved(dx, dy, row, col)
```

Sends a scroll event to the editor.

```lua
neovim:setSize(width, height)
```

Resize the editor.  `width` and `height` are in pixels.  Note that this is a request to the server,
and the actual size may end up being smaller, since the size of the editor is determined by the
smallest connected client.  This may change the number of rows and columns.

```lua
neovim:setFont(font, size)
```

Set a new font.  `size` is in pixels.  This may change the number of rows and columns.

    neovim.width
    neovim.height
    neovim.colsize
    neovim.rowsize
    neovim.cols
    neovim.rows

Get various dimensions of the editor.  All sizes are in pixels.

License
---

MIT, see [`LICENSE`](LICENSE) for details.
