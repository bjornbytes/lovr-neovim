local mp = require 'mp'
local uv = require 'luv'

local function defaultcolor(color) return 0x8000000 + color end
local function isdefaultcolor(color) return color >= 0x8000000 end

local neovim = {}

function neovim.new(config)
  local editor = setmetatable({}, neovim)
  editor:init(config)
  return editor
end

function neovim:init(config)
  config = config or {}

  self:setSize(config.width or 800, config.height or 600)
  self:setFont(config.font or lovr.graphics.getDefaultFont(), config.fontSize or 16)
  self.onquit = config.quit or lovr.event.quit
  self.onfontchanged = config.fontchanged
  self.onerror = config.onerror or error
  self.capsescape = config.capsescape

  self.mode = 0
  self.grids = {}
  self.highlights = {}
  self.highlights[0] = {}
  self.highlights[0].foreground = defaultcolor(0xffffff)
  self.highlights[0].background = defaultcolor(0x000000)

  if config.address then
    local host = config.address:match('^[%d%.]+')
    local port = tonumber(config.port or config.address:match(':(%d+)'))
    if not host then self.onerror('Invalid server address') end
    if not port then self.onerror('Invalid port number') end

    self.stream = uv.new_tcp()
    self.stream:nodelay(true)

    local ok, err = self.stream:connect(host, port, function(err)
      if err then self.onerror(err) end
      self:attach(self.stream)
    end)

    if not ok then self.onerror(err) end
  else
    self.stream = uv.new_pipe()
    self.stdout = uv.new_pipe()

    local options = {
      args = { '--embed' },
      stdio = { self.stream, self.stdout, 1 },
      cwd = config.cwd or lovr.filesystem.getWorkingDirectory()
    }

    local process, err = uv.spawn(config.exe or 'nvim', options, function()
      self.connected = false
      self.process:close()
    end)

    if process then
      self.process = process
    else
      self.onerror(err)
    end

    self:attach(self.stdout)
  end
end

function neovim:attach(stream)
  self.connected = true
  self.callbacks = {}
  self.buffer = ''
  self.seq = 1

  stream:read_start(function(err, data)
    if err then
      self.onerror(err)
    elseif data then
      self:feed(data)
    elseif self.onquit then
      self.connected = false
      self.onquit()
    end
  end)

  self:request('nvim_ui_attach', { self.cols, self.rows, { ext_linegrid = true } })
end

function neovim:feed(data)
  self.buffer = self.buffer .. data

  while true do
    local success, message, offset = pcall(mp.decode, self.buffer)

    if not success then
      break
    end

    if type(message) == 'table' then
      if message[1] == 1 then
        local seq, err, result = unpack(message, 2)

        if err then
          self.onerror(err[2] or 'neovim msgpack error!')
        elseif self.callbacks[seq] then
          self.callbacks[seq](result)
          self.callbacks[seq] = nil
        end
      elseif message[1] == 2 then
        local method, args = unpack(message, 2)
        if self[method] then self[method](self, args) end
      end
    end

    if offset then
      self.buffer = self.buffer:sub(offset)
    else
      self.buffer = ''
      break
    end
  end
end

function neovim:request(method, args, callback)
  if not self.connected then return end
  self.stream:write(mp.encode({ 0, self.seq, method, mp.array(args) }))
  self.callbacks[self.seq] = callback
  self.seq = self.seq + 1
end

function neovim:notify(method, args)
  self.stream:write(mp.encode({ 2, method, mp.array(args) }))
end

function neovim:redraw(events)
  for i, event in ipairs(events) do
    if self[event[1]] then
      for i = 2, #event do
        self[event[1]](self, unpack(event[i]))
      end
    end
  end
end

function neovim:default_colors_set(fg, bg)
  self.highlights[0].foreground = defaultcolor(fg)
  self.highlights[0].background = defaultcolor(bg)
  for index, grid in pairs(self.grids) do
    for r, row in ipairs(grid.lines) do
      for c = 1, grid.cols do
        if isdefaultcolor(row[2 * c - 1]) then row[2 * c - 1] = defaultcolor(fg) end
        if isdefaultcolor(row.background[c]) then row.background[c] = defaultcolor(bg) end
      end
    end
  end
end

function neovim:option_set(name, value)
  if name == 'guifont' and self.onfontchanged then
    self.onfontchanged(value)
  end
end

function neovim:mode_info_set(cursor, modes)
  self.modes = modes
end

function neovim:mode_change(name, index)
  self.mode = index + 1
end

function neovim:hl_attr_define(id, properties)
  self.highlights[id] = properties
end

function neovim:grid_resize(index, cols, rows)
  if not self.grids[index] then
    self.grids[index] = { lines = {}, cx = 0, cy = 0 }
  end

  local grid = self.grids[index]

  grid.cols = cols
  grid.rows = rows

  while #grid.lines > rows do
    table.remove(grid.lines)
  end

  for i, line in ipairs(grid.lines) do
    while #line > 2 * cols do
      table.remove(line)
      table.remove(line)
      table.remove(line.background)
    end
  end

  while #grid.lines < rows do
    local line = { background = {} }
    table.insert(grid.lines, line)

    for i = 1, cols do
      table.insert(line, self.highlights[0].foreground)
      table.insert(line, '')
      table.insert(line.background, self.highlights[0].background)
    end
  end
end

function neovim:grid_clear(index)
  local grid = self.grids[index]
  if not grid then return end
  for r, line in ipairs(grid.lines) do
    for c = 1, grid.cols do
      line[2 * c - 1] = self.highlights[0].foreground
      line[2 * c - 0] = ''
      line.background[c] = self.highlights[0].background
    end
  end
end

function neovim:grid_destroy(index)
  self.grids[index] = nil
end

function neovim:grid_line(index, row, col, cells, wrap)
  local grid = self.grids[index]
  if not grid then return end
  local highlight
  local line = grid.lines[row + 1]
  for _, cell in ipairs(cells) do
    local char, hl, count = unpack(cell)
    for i = 1, count or 1 do
      highlight = hl and self.highlights[hl] or highlight or self.highlights[0]
      line[col * 2 + 1] = highlight.foreground or self.highlights[0].foreground
      line[col * 2 + 2] = char
      line.background[col + 1] = highlight.background or self.highlights[0].background
      col = col + 1
    end
  end
end

function neovim:grid_scroll(index, top, bot, left, right, rows, cols)
  local grid = self.grids[index]
  if not grid then return end
  if rows > 0 then
    for i = 1, rows do
      local row = table.remove(grid.lines, top + 1)
      table.insert(grid.lines, bot, row)
    end
  else
    for i = 1, -rows do
      local row = table.remove(grid.lines, bot)
      table.insert(grid.lines, top + 1, row)
    end
  end
end

function neovim:grid_cursor_goto(index, row, col)
  local grid = self.grids[index]
  if not grid then return end
  grid.cx, grid.cy = col, row
end

function neovim:flush()
  self.dirty = true
end

function neovim:update()
  uv.run('nowait')
  return self.dirty
end

function neovim:draw(pass)
  if not self.grids[1] then return end

  local W, H = self.colsize, self.rowsize
  local ortho = pass:getProjection(1, mat4())[16] == 1
  if not ortho then H = -H end

  pass:push('state')
  pass:setFont(self.font)

  -- Background
  local x, y, z, col = 0, H / 2, 0, 1
  for i, line in ipairs(self.grids[1].lines) do
    while col <= #line.background do
      local count = 1
      local color = line.background[col]
      while line.background[col + count] == color do count = count + 1 end
      local width = count * W

      pass:setColor(color)
      pass:plane(x + width / 2, y, z, width, H)

      col = col + count
      x = x + width
    end
    x, y, col = 0, y + H, 1
  end

  -- Text
  y = 0
  pass:setColor(0xffffff)
  pass:setDepthOffset(5, 5)
  for i, line in ipairs(self.grids[1].lines) do
    pass:text(line, 0, y, 0, self.fontScale, nil, 0, 'left', 'top')
    y = y + H
  end

  -- Cursor
  if self.grids[1] and self.modes then
    local grid = self.grids[1]
    local mode = self.modes[self.mode]
    local color = (self.highlights[mode.attr_id] or self.highlights[0]).foreground
    local x, y, z, w, h

    z = ortho and -.001 or .001

    if mode.cursor_shape == 'block' then
      x = grid.cx * W + W * .5
      y = grid.cy * H + H * .5
      w = W
      h = H
    elseif mode.cursor_shape == 'vertical' then
      local cw = mode.cell_percentage / 100 * W
      x = grid.cx * W + cw * .5
      y = grid.cy * H + H * .5
      w = cw
      h = math.abs(H)
    elseif mode.cursor_shape == 'horizontal' then
      local ch = mode.cell_percentage / 100 * math.abs(H)
      x = grid.cx * W + W * .5
      y = grid.cy * H + H - ch * .5
      w = W
      h = ch
    end

    pass:setColor(color)
    pass:plane(x, y, z, w, h)
  end

  pass:pop('state')

  self.dirty = false
end

function neovim:quit()
  if not self.connected then return end
  if self.process then
    self.process:close()
  elseif self.stream then
    self.stream:shutdown()
  end
end

function neovim:keypressed(key)
  local special = {
    backspace = 'BS',
    tab = 'Tab',
    ['return'] = 'CR',
    escape = 'Esc',
    delete = 'Del',
    up = 'Up',
    down = 'Down',
    left = 'Left',
    right = 'Right',
    f1 = 'F1',
    f2 = 'F2',
    f3 = 'F3',
    f4 = 'F4',
    f5 = 'F5',
    f6 = 'F6',
    f7 = 'F7',
    f8 = 'F8',
    f9 = 'F9',
    f10 = 'F10',
    f11 = 'F11',
    f12 = 'F12',
    insert = 'Insert',
    home = 'Home',
    ['end'] = 'End',
    pageup = 'PageUp',
    pagedown = 'PageDown'
  }

  if key == 'capslock' and self.capsescape then key = 'escape' end

  if key:match('[lr]ctrl') then
    self.ctrl = true
  elseif key:match('[lr]shift') then
    self.shift = true
  elseif key:match('[lr]alt') then
    self.alt = true
  elseif special[key] or self.ctrl or (self.shift and special[key]) or self.alt then
    local ctrl = self.ctrl and 'C-' or ''
    local shift = self.shift and 'S-' or ''
    local alt = self.alt and 'A-' or ''
    local input = ('<%s%s%s%s>'):format(ctrl, shift, alt, special[key] or key)
    self:request('nvim_input', { input })
  end
end

function neovim:keyreleased(key)
  if key:match('[lr]ctrl') then
    self.ctrl = false
  elseif key:match('[lr]shift') then
    self.shift = false
  elseif key:match('[lr]alt') then
    self.alt = false
  end
end

function neovim:textinput(text)
  if #text == 1 and text:byte(1) < 32 then return end

  local symbols = {
    ['<'] = '<lt>',
    ['\\'] = '<Bslash>',
    ['|'] = '<Bar>'
  }

  self:request('nvim_input', { symbols[text] or text })
end

function neovim:mousepressed(button, row, col)
  self:mouse('press', button, row, col)
  self.pressed = true
end

function neovim:mousereleased(button, row, col)
  self:mouse('release', button, row, col)
  self.pressed = false
end

function neovim:mousemoved(row, col)
  self:mouse('drag', 'move', row, col)
end

function neovim:wheelmoved(dx, dy, row, col)
  if dx == 0 and dy == 0 then return end
  local direction = dx > 0 and 'right' or dx < 0 and 'left' or dy > 0 and 'up' or dy < 0 and 'down'
  self:mouse(direction, 'wheel', row, col)
end

function neovim:mouse(action, button, row, col)
  if not row or not col then return end
  local buttons = { [1] = 'left', [2] = 'right', [3] = 'middle', [4] = 'x1', [5] = 'x2' }
  local mods = (self.ctrl and 'c' or '') .. (self.shift and 's' or '') .. (self.alt and 'a' or '')
  button = buttons[button] or button
  if button == 'move' and self.pressed then button = 'left' end
  self:request('nvim_input_mouse', { button, action, mods, 0, row - 1, col - 1 })
end

function neovim:setSize(width, height)
  self.width, self.height = width, height
  self:resize()
end

function neovim:setFont(font, size)
  self.font = font
  self.fontScale = size / self.font:getHeight()
  self.rowsize = size
  self.colsize = self.font:getWidth('W') * self.fontScale
  self:resize()
end

function neovim:resize()
  if not self.width or not self.height or not self.font then return end

  local cols = math.floor(self.width / self.colsize)
  local rows = math.floor(self.height / self.rowsize)

  if cols ~= self.cols or rows ~= self.rows then
    self:request('nvim_ui_try_resize', { cols, rows })
    self.cols, self.rows = cols, rows
  end
end

neovim.__index = neovim
return setmetatable({}, neovim)
