local neovim = require 'neovim'

function lovr.load()
  lovr.graphics.setBackgroundColor(.1, .1, .12)
  lovr.system.setKeyRepeat(true)

  pose = Mat4(0, 1.7, -1)
  width = 1.4
  height = 1
  cursors = {}

  useLayer = true and lovr.headset.getDriver() ~= 'simulator'
  ppm = useLayer and 1500 or 1

  if useLayer then
    layer = lovr.headset.newLayer(width * ppm, height * ppm)
    lovr.headset.setLayers(layer)
    layer:setDimensions(width, height)
    layer:setPose(pose)
  end

  neovim:init({
    address = arg[1],
    capsescape = true,
    width = width * ppm,
    height = height * ppm,
    font = lovr.graphics.newFont('JetBrainsMono.ttf'),
    fontSize = .04 * ppm
  })
end

function lovr.update(dt)
  for i, hand in ipairs(lovr.headset.getHands()) do
    local pointer = hand .. '/point'

    -- Lazily initialize cursor
    if not cursors[hand] then
      cursors[hand] = {
        position = Vec3(),
        direction = Vec3(),
        inside = false,
        scroll = 0,
        row = 0,
        col = 0,
        x = 0,
        y = 0
      }
    end

    local cursor = cursors[hand]

    cursor.position:set(lovr.headset.getPosition(pointer))
    cursor.direction:set(lovr.headset.getDirection(pointer))

    -- Get cursor ray relative to editor
    local inverse = mat4(pose):invert()
    local origin = inverse * cursor.position
    local direction = quat(inverse) * cursor.direction

    -- Intersect cursor with plane
    local t = -origin.z / direction.z
    local x, y = (origin + direction * t):unpack()

    cursor.x, cursor.y = x, y
    cursor.inside = t > 0 and x > -width/2 and x < width/2 and y > -height/2 and y < height/2

    -- Virtual mouse events
    if cursor.inside then
      local col = math.floor((x + neovim.width / ppm / 2) / neovim.colsize / ppm) + 1
      local row = math.floor((neovim.height / ppm / 2 - y) / neovim.rowsize / ppm) + 1

      if cursor.row ~= row or cursor.col ~= col then
        cursor.row, cursor.col = row, col
        neovim:mousemoved(row, col)
      end

      if lovr.headset.wasPressed(hand, 'trigger') then
        neovim:mousepressed(1, row, col)
      elseif lovr.headset.wasReleased(hand, 'trigger') then
        neovim:mousereleased(1, row, col)
      end
    end

    -- Scrolling
    local _, scroll = lovr.headset.getAxis(hand, 'thumbstick')
    local prevScroll = cursor.scroll
    local scrollSpeed = 25

    if math.abs(scroll) > .25 then
      cursor.scroll = cursor.scroll + scroll * dt * scrollSpeed
      if math.floor(cursor.scroll) ~= math.floor(prevScroll) then
        neovim:wheelmoved(0, cursor.scroll - prevScroll > 0 and 1 or -1, cursor.row, cursor.col)
      end
    end
  end

  dirty = neovim:update()
end

function lovr.draw(pass)
  pass:push()
  pass:transform(pose)

  -- if using a layer, only redraw the layer if editor changed
  -- if not using a layer, always draw editor on 3D plane in main pass
  local layerPass = useLayer and dirty and layer:getPass()

  -- editor
  if layerPass then
    neovim:draw(layerPass)
  elseif not useLayer then
    pass:push()
    pass:translate(-neovim.width / 2, neovim.height / 2, 1e-3)
    pass:setColor(0xffffff)
    neovim:draw(pass)
    pass:pop()
  end

  -- border
  local padding = .02
  local thickness = .02
  pass:setColor(0x303032)
  pass:roundrect(0, 0, -thickness / 2, width + 2 * padding, height + 2 * padding, thickness, nil, .02)

  -- cursors
  for hand, cursor in pairs(cursors) do
    if cursor.inside then
      pass:setColor(0xffffff)
      pass:circle(cursor.x, cursor.y, 2e-3, lovr.headset.isDown(hand, 'trigger') and .010 or .008)
    end
  end

  -- back to world space
  pass:pop()

  -- hands
  for hand, cursor in pairs(cursors) do
    pass:setColor(0xffffff)
    pass:sphere(cursor.position, .005)
  end

  return lovr.graphics.submit(layerPass, pass)
end

function lovr.quit()
  neovim:quit()
end

function lovr.keypressed(...)
  neovim:keypressed(...)
end

function lovr.keyreleased(...)
  neovim:keyreleased(...)
end

function lovr.textinput(...)
  neovim:textinput(...)
end

function lovr.wheelmoved(dx, dy)
  neovim:wheelmoved(dx, dy, 1, 1)
end
